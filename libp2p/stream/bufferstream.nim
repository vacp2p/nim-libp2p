## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## This module implements an asynchronous buffer stream
## which emulates physical async IO.
##
## The stream is based on the standard library's `Deque`,
## which is itself based on a ring buffer.
##
## It works by exposing a regular LPStream interface and
## a method ``pushTo`` to push data to the internal read
## buffer; as well as a handler that can be registrered
## that gets triggered on every write to the stream. This
## allows using the buffered stream as a sort of proxy,
## which can be consumed as a regular LPStream but allows
## injecting data for reads and intercepting writes.
##
## Another notable feature is that the stream is fully
## ordered and asynchronous. Reads are queued up in order
## and are suspended when not enough data available. This
## allows preserving backpressure while maintaining full
## asynchrony. Both writting to the internal buffer with
## ``pushTo`` as well as reading with ``read*` methods,
## will suspend until either the amount of elements in the
## buffer goes below ``maxSize`` or more data becomes available.

import deques, math, oids
import chronos, chronicles, metrics
import ../stream/lpstream

export lpstream

logScope:
  topic = "BufferStream"

const
  BufferStreamTrackerName* = "libp2p.bufferstream"
  DefaultBufferSize* = 1024

type
  # TODO: figure out how to make this generic to avoid casts
  WriteHandler* = proc (data: seq[byte]): Future[void] {.gcsafe.}

  BufferStream* = ref object of LPStream
    maxSize*: int # buffer's max size in bytes
    readBuf: Deque[byte] # this is a ring buffer based dequeue, this makes it perfect as the backing store here
    readReqs: Deque[Future[void]] # use dequeue to fire reads in order
    dataReadEvent: AsyncEvent
    writeHandler*: WriteHandler
    lock: AsyncLock
    isPiped: bool

  AlreadyPipedError* = object of CatchableError
  NotWritableError* = object of CatchableError

  BufferStreamTracker* = ref object of TrackerBase
    opened*: uint64
    closed*: uint64

proc setupBufferStreamTracker(): BufferStreamTracker {.gcsafe.}

proc getBufferStreamTracker(): BufferStreamTracker {.gcsafe.} =
  result = cast[BufferStreamTracker](getTracker(BufferStreamTrackerName))
  if isNil(result):
    result = setupBufferStreamTracker()

proc dumpTracking(): string {.gcsafe.} =
  var tracker = getBufferStreamTracker()
  result = "Opened buffers: " & $tracker.opened & "\n" &
           "Closed buffers: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getBufferStreamTracker()
  result = (tracker.opened != tracker.closed)

proc setupBufferStreamTracker(): BufferStreamTracker =
  result = new BufferStreamTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTracking
  result.isLeaked = leakTransport
  addTracker(BufferStreamTrackerName, result)
declareGauge libp2p_open_bufferstream, "open BufferStream instances"

proc newAlreadyPipedError*(): ref Exception {.inline.} =
  result = newException(AlreadyPipedError, "stream already piped")

proc newNotWritableError*(): ref Exception {.inline.} =
  result = newException(NotWritableError, "stream is not writable")

proc requestReadBytes(s: BufferStream): Future[void] =
  ## create a future that will complete when more
  ## data becomes available in the read buffer
  result = newFuture[void]()
  s.readReqs.addLast(result)
  trace "requestReadBytes(): added a future to readReqs"

proc initBufferStream*(s: BufferStream,
                       handler: WriteHandler = nil,
                       size: int = DefaultBufferSize) =
  s.maxSize = if isPowerOfTwo(size): size else: nextPowerOfTwo(size)
  s.readBuf = initDeque[byte](s.maxSize)
  s.readReqs = initDeque[Future[void]]()
  s.dataReadEvent = newAsyncEvent()
  s.lock = newAsyncLock()

  if not(isNil(s.writeHandler)):
    s.writeHandler = proc (data: seq[byte]) {.async, gcsafe.} =
      defer:
        s.writeLock.release()
      await s.writeLock.acquire()

      await handler(data)

  s.closeEvent = newAsyncEvent()
  inc getBufferStreamTracker().opened
  when chronicles.enabledLogLevel == LogLevel.TRACE:
    s.oid = genOid()
  s.isClosed = false
  libp2p_open_bufferstream.inc()

proc newBufferStream*(handler: WriteHandler = nil,
                      size: int = DefaultBufferSize): BufferStream =
  new result
  result.initBufferStream(handler, size)

proc popFirst*(s: BufferStream): byte =
  result = s.readBuf.popFirst()
  s.dataReadEvent.fire()

proc popLast*(s: BufferStream): byte =
  result = s.readBuf.popLast()
  s.dataReadEvent.fire()

proc shrink(s: BufferStream, fromFirst = 0, fromLast = 0) =
  s.readBuf.shrink(fromFirst, fromLast)
  s.dataReadEvent.fire()

proc len*(s: BufferStream): int = s.readBuf.len

proc pushTo*(s: BufferStream, data: seq[byte]) {.async.} =
  ## Write bytes to internal read buffer, use this to fill up the
  ## buffer with data.
  ##
  ## This method is async and will wait until  all data has been
  ## written to the internal buffer; this is done so that backpressure
  ## is preserved.
  ##

  when chronicles.enabledLogLevel == LogLevel.TRACE:
    logScope:
      stream_oid = $s.oid

  if s.atEof:
    raise newLPStreamEOFError()

  try:
    await s.lock.acquire()
    var index = 0
    while not s.closed():
      while index < data.len and s.readBuf.len < s.maxSize:
        s.readBuf.addLast(data[index])
        inc(index)
      trace "pushTo()", msg = "added " & $index & " bytes to readBuf"

      # resolve the next queued read request
      if s.readReqs.len > 0:
        s.readReqs.popFirst().complete()
        trace "pushTo(): completed a readReqs future"

      if index >= data.len:
        return

      # if we couldn't transfer all the data to the
      # internal buf wait on a read event
      await s.dataReadEvent.wait()
      s.dataReadEvent.clear()
  finally:
    s.lock.release()

method readExactly*(s: BufferStream,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] {.async.} =
  ## Read exactly ``nbytes`` bytes from read-only stream ``rstream`` and store
  ## it to ``pbytes``.
  ##
  ## If EOF is received and ``nbytes`` is not yet read, the procedure
  ## will raise ``LPStreamIncompleteError``.
  ##
  when chronicles.enabledLogLevel == LogLevel.TRACE:
    logScope:
      stream_oid = $s.oid

  if s.atEof:
    raise newLPStreamEOFError()

  trace "read()", requested_bytes = nbytes
  var index = 0

  if s.readBuf.len() == 0:
    await s.requestReadBytes()

  let output = cast[ptr UncheckedArray[byte]](pbytes)
  while index < nbytes:
    while s.readBuf.len() > 0 and index < nbytes:
      output[index] = s.popFirst()
      inc(index)
    trace "readExactly()", read_bytes = index

    if index < nbytes:
      await s.requestReadBytes()

method readOnce*(s: BufferStream,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async.} =
  ## Perform one read operation on read-only stream ``rstream``.
  ##
  ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
  ## internal buffer, otherwise it will wait until some bytes will be received.
  ##

  if s.atEof:
    raise newLPStreamEOFError()

  if s.readBuf.len == 0:
    await s.requestReadBytes()

  var len = if nbytes > s.readBuf.len: s.readBuf.len else: nbytes
  await s.readExactly(pbytes, len)
  result = len

method write*(s: BufferStream, msg: seq[byte]): Future[void] =
  ## Write sequence of bytes ``sbytes`` of length ``msglen`` to writer
  ## stream ``wstream``.
  ##
  ## Sequence of bytes ``sbytes`` must not be zero-length.
  ##
  ## If ``msglen < 0`` whole sequence ``sbytes`` will be writen to stream.
  ## If ``msglen > len(sbytes)`` only ``len(sbytes)`` bytes will be written to
  ## stream.
  ##

  if s.closed:
    raise newLPStreamClosedError()

  if isNil(s.writeHandler):
    var retFuture = newFuture[void]("BufferStream.write(seq)")
    retFuture.fail(newNotWritableError())
    return retFuture

  result = s.writeHandler(msg)

proc pipe*(s: BufferStream,
           target: BufferStream): BufferStream =
  ## pipe the write end of this stream to
  ## be the source of the target stream
  ##
  ## Note that this only works with the LPStream
  ## interface methods `read*` and `write` are
  ## piped.
  ##
  if s.isPiped:
    raise newAlreadyPipedError()

  s.isPiped = true
  let oldHandler = target.writeHandler
  proc handler(data: seq[byte]) {.async, closure, gcsafe.} =
    if not isNil(oldHandler):
      await oldHandler(data)

    # if we're piping to self,
    # then add the data to the
    # buffer directly and fire
    # the read event
    if s == target:
      for b in data:
        s.readBuf.addLast(b)

      # notify main loop of available
      # data
      s.dataReadEvent.fire()
    else:
      await target.pushTo(data)

  s.writeHandler = handler
  result = target

proc `|`*(s: BufferStream, target: BufferStream): BufferStream =
  ## pipe operator to make piping less verbose
  pipe(s, target)

method close*(s: BufferStream) {.async.} =
  ## close the stream and clear the buffer
  if not s.isClosed:
    trace "closing bufferstream"
    for r in s.readReqs:
      if not(isNil(r)) and not(r.finished()):
        r.fail(newLPStreamEOFError())
    s.dataReadEvent.fire()
    s.readBuf.clear()

    inc getBufferStreamTracker().closed
    libp2p_open_bufferstream.dec()
  else:
    trace "attempt to close an already closed bufferstream", trace=getStackTrace()

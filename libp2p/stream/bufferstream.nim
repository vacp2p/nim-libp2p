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
## buffer; as well as a handler that can be registered
## that gets triggered on every write to the stream. This
## allows using the buffered stream as a sort of proxy,
## which can be consumed as a regular LPStream but allows
## injecting data for reads and intercepting writes.
##
## Another notable feature is that the stream is fully
## ordered and asynchronous. Reads are queued up in order
## and are suspended when not enough data available. This
## allows preserving backpressure while maintaining full
## asynchrony. Both writing to the internal buffer with
## ``pushTo`` as well as reading with ``read*` methods,
## will suspend until either the amount of elements in the
## buffer goes below ``maxSize`` or more data becomes available.

import deques, math
import chronos, chronicles, metrics
import ../stream/connection

when chronicles.enabledLogLevel == LogLevel.TRACE:
  import oids

export connection

logScope:
  topics = "bufferstream"

const
  DefaultBufferSize* = 10

const
  BufferStreamTrackerName* = "libp2p.bufferstream"

type
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

type
  # TODO: figure out how to make this generic to avoid casts
  WriteHandler* = proc (data: seq[byte]): Future[void] {.gcsafe.}

  BufferStream* = ref object of Connection
    maxSize*: int                     # buffer's max size in bytes
    readBuf: Deque[byte]              # this is a ring buffer based dequeue
    readReqs*: Deque[Future[void]]    # use dequeue to fire reads in order
    dataReadEvent*: AsyncEvent        # event triggered when data has been consumed from the internal buffer
    writeHandler*: WriteHandler       # user provided write callback
    writeLock*: AsyncLock             # write lock to guarantee ordered writes
    lock: AsyncLock                   # pushTo lock to guarantee ordered reads
    piped: BufferStream               # a piped bufferstream instance

  AlreadyPipedError* = object of CatchableError
  NotWritableError* = object of CatchableError

proc newAlreadyPipedError*(): ref CatchableError {.inline.} =
  result = newException(AlreadyPipedError, "stream already piped")

proc newNotWritableError*(): ref CatchableError {.inline.} =
  result = newException(NotWritableError, "stream is not writable")

proc requestReadBytes(s: BufferStream): Future[void] =
  ## create a future that will complete when more
  ## data becomes available in the read buffer
  result = newFuture[void]()
  s.readReqs.addLast(result)
  # trace "requestReadBytes(): added a future to readReqs", oid = s.oid

method initStream*(s: BufferStream) =
  if s.objName.len == 0:
    s.objName = "BufferStream"

  procCall Connection(s).initStream()
  inc getBufferStreamTracker().opened

proc initBufferStream*(s: BufferStream,
                       handler: WriteHandler = nil,
                       size: int = DefaultBufferSize) =
  s.initStream()

  s.maxSize = if isPowerOfTwo(size): size else: nextPowerOfTwo(size)
  s.readBuf = initDeque[byte](s.maxSize)
  s.readReqs = initDeque[Future[void]]()
  s.dataReadEvent = newAsyncEvent()
  s.lock = newAsyncLock()
  s.writeLock = newAsyncLock()

  if not(isNil(handler)):
    s.writeHandler = proc (data: seq[byte]) {.async, gcsafe.} =
      defer:
        s.writeLock.release()

      # Using a lock here to guarantee
      # proper write ordering. This is
      # specially important when
      # implementing half-closed in mplex
      # or other functionality that requires
      # strict message ordering
      await s.writeLock.acquire()
      await handler(data)

  trace "created bufferstream", oid = $s.oid

proc newBufferStream*(handler: WriteHandler = nil,
                      size: int = DefaultBufferSize,
                      timeout: Duration = DefaultConnectionTimeout): BufferStream =
  new result
  result.timeout = timeout
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

method pushTo*(s: BufferStream, data: seq[byte]) {.base, async.} =
  ## Write bytes to internal read buffer, use this to fill up the
  ## buffer with data.
  ##
  ## This method is async and will wait until  all data has been
  ## written to the internal buffer; this is done so that backpressure
  ## is preserved.
  ##

  if s.atEof:
    raise newLPStreamEOFError()

  defer:
    # trace "ended", size = s.len
    s.lock.release()

  await s.lock.acquire()
  var index = 0
  while not s.closed():
    while index < data.len and s.readBuf.len < s.maxSize:
      s.readBuf.addLast(data[index])
      inc(index)
    # trace "pushTo()", msg = "added " & $s.len & " bytes to readBuf", oid = s.oid

    # resolve the next queued read request
    if s.readReqs.len > 0:
      s.readReqs.popFirst().complete()
      # trace "pushTo(): completed a readReqs future", oid = s.oid

    if index >= data.len:
      return

    # if we couldn't transfer all the data to the
    # internal buf wait on a read event
    await s.dataReadEvent.wait()
    s.dataReadEvent.clear()

proc drainBuffer*(s: BufferStream) {.async.} =
  ## wait for all data in the buffer to be consumed
  ##

  trace "draining buffer", len = s.len, oid = $s.oid
  while s.len > 0:
    await s.dataReadEvent.wait()
    s.dataReadEvent.clear()

method readOnce*(s: BufferStream,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async.} =
  if s.atEof:
    raise newLPStreamEOFError()

  if s.len() == 0:
    await s.requestReadBytes()

  var index = 0
  var size = min(nbytes, s.len)
  let output = cast[ptr UncheckedArray[byte]](pbytes)

  s.activity = true # reset activity flag
  while s.len() > 0 and index < size:
    output[index] = s.popFirst()
    inc(index)

  return size

method write*(s: BufferStream, msg: seq[byte]) {.async.} =
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
    raise newNotWritableError()

  s.activity = true # reset activity flag
  await s.writeHandler(msg)

# TODO: move pipe routines out
proc pipe*(s: BufferStream,
           target: BufferStream): BufferStream =
  ## pipe the write end of this stream to
  ## be the source of the target stream
  ##
  ## Note that this only works with the LPStream
  ## interface methods `read*` and `write` are
  ## piped.
  ##
  if not(isNil(s.piped)):
    raise newAlreadyPipedError()

  s.piped = target
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

method close*(s: BufferStream) {.async, gcsafe.} =
  try:
    ## close the stream and clear the buffer
    if not s.isClosed:
      trace "closing bufferstream", oid = $s.oid
      s.isEof = true
      for r in s.readReqs:
        if not(isNil(r)) and not(r.finished()):
          r.fail(newLPStreamEOFError())
      s.dataReadEvent.fire()
      s.readBuf.clear()

      await procCall Connection(s).close()
      inc getBufferStreamTracker().closed
      trace "bufferstream closed", oid = $s.oid
    else:
      trace "attempt to close an already closed bufferstream",
        trace = getStackTrace(), oid = $s.oid
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error closing buffer stream", exc = exc.msg

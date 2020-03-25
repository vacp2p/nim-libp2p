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

import deques, math, sequtils
import chronos, chronicles
import ../stream/lpstream

type
  # TODO: figure out how to make this generic to avoid casts
  WriteHandler* = proc (data: seq[byte]): Future[void] {.gcsafe.}

  BufferStream* = ref object of LPStream
    queue*: AsyncQueue[seq[byte]]
    writeHandler*: WriteHandler
    lock: AsyncLock
    isPiped: bool

  AlreadyPipedError* = object of CatchableError
  NotWritableError* = object of CatchableError

proc newAlreadyPipedError*(): ref Exception {.inline.} =
  result = newException(AlreadyPipedError, "stream already piped")

proc newNotWritableError*(): ref Exception {.inline.} =
  result = newException(NotWritableError, "stream is not writable")

proc initBufferStream*(s: BufferStream,
                       handler: WriteHandler = nil) =
  initLPStream(s)

  s.queue = newAsyncQueue[seq[byte]]()

  s.writeHandler = handler

proc newBufferStream*(handler: WriteHandler = nil): BufferStream =
  new result
  result.initBufferStream(handler)

proc len*(s: BufferStream): int = s.queue.len

proc pushTo*(s: BufferStream, data: seq[byte]) {.async.} =
  ## Write bytes to internal read buffer, use this to fill up the
  ## buffer with data.
  ##
  ## This method is async and will wait until  all data has been
  ## written to the internal buffer; this is done so that backpressure
  ## is preserved.
  ##
  if data.len() > 0:
    await s.queue.put(data)

method readOnce*(s: BufferStream): Future[seq[byte]] {.async.} =
  ## Perform one read operation on read-only stream ``rstream``.
  ##
  ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
  ## internal buffer, otherwise it will wait until some bytes will be received.
  ##
  if s.queue.len == 0:
    if s.closed():
      return
  result = await s.queue.get()
  if result.len() == 0:
    raise newLPStreamEOFError()

method write*(s: BufferStream,
              msg: seq[byte],
              msglen = -1): Future[void] =
  ## Write sequence of bytes ``sbytes`` of length ``msglen`` to writer
  ## stream ``wstream``.
  ##
  ## Sequence of bytes ``sbytes`` must not be zero-length.
  ##
  ## If ``msglen < 0`` whole sequence ``sbytes`` will be writen to stream.
  ## If ``msglen > len(sbytes)`` only ``len(sbytes)`` bytes will be written to
  ## stream.
  ##
  if isNil(s.writeHandler):
    var retFuture = newFuture[void]("BufferStream.write(seq)")
    retFuture.fail(newNotWritableError())
    return retFuture

  var buf: seq[byte]
  shallowCopy(buf, if msglen > 0: msg[0..<msglen] else: msg)
  result = s.writeHandler(buf)

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

    await target.pushTo(data)

  s.writeHandler = handler
  result = target

proc `|`*(s: BufferStream, target: BufferStream): BufferStream =
  ## pipe operator to make piping less verbose
  pipe(s, target)

method close*(s: BufferStream) {.async.} =
  ## close the stream and clear the buffer
  if not s.isClosed:
    s.closeEvent.fire()
    s.isClosed = true

    await s.queue.put(@[])

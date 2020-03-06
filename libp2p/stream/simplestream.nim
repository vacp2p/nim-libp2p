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

import chronos
import ../stream/lpstream

type
  # TODO: figure out how to make this generic to avoid casts
  WriteHandler* = proc (data: seq[byte]): Future[void]
  ReadHandler* = proc (): Future[seq[byte]]

  SimpleStream* = ref object of LPStream
    maxSize*: int # buffer's max size in bytes
    writeHandler*: WriteHandler
    readHandler*: ReadHandler
    buf*: seq[byte]

  NotWritableError* = object of CatchableError

proc newNotWritableError*(): ref Exception {.inline.} =
  result = newException(NotWritableError, "stream is not writable")

proc initSimpleStream*(s: SimpleStream,
                       writeHandler: WriteHandler = nil,
                       readHandler: ReadHandler = nil,
                       maxSize: int = -1) =
  s.maxSize = if maxSize <= 0: int.high else: maxSize
  s.writeHandler = writeHandler
  s.readHandler = readHandler
  s.closeEvent = newAsyncEvent()

proc newSimpleStream*(writeHandler: WriteHandler = nil,
                      readHandler: ReadHandler = nil,
                      maxSize: int = -1): SimpleStream =
  new result
  result.initSimpleStream(writeHandler, readHandler, maxSize)

func shift(s: var seq[byte], bytes: int) =
  if bytes >= s.len:
    s.setLen(0)
  else:
    moveMem(addr s[0], addr s[bytes], s.len - bytes)
    s.setLen(s.len - bytes)

proc len*(s: SimpleStream): int = s.buf.len

method read*(s: SimpleStream, n = -1): Future[seq[byte]] {.async.} =
  ## Read all bytes (n <= 0) or at most `n` bytes from buffer
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  ##

  if n <= 0:
    result.add s.buf
    s.buf.setLen(0)

    while true:
      let bytes = await s.readHandler()
      if bytes.len == 0:
        break
      result.add bytes
  else:
    var
      bytes = s.buf
      count = min(n, bytes.len())

    result.add bytes.toOpenArray(0, count - 1)

    while result.len < n:
      bytes = await s.readHandler()
      count = min(n - result.len(), bytes.len())

      if bytes.len() == 0:
        break

      result.add bytes.toOpenArray(0, count - 1)

    s.buf.shift(count)

method readExactly*(s: SimpleStream,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] {.async.} =
  ## Read exactly ``nbytes`` bytes from read-only stream ``rstream`` and store
  ## it to ``pbytes``.
  ##
  ## If EOF is received and ``nbytes`` is not yet read, the procedure
  ## will raise ``LPStreamIncompleteError``.
  ##
  var
    pos = 0
    dest = cast[ptr UncheckedArray[byte]](pbytes)

  while pos < nbytes:
    if s.buf.len > 0:
      let count = min(nbytes - pos, s.buf.len())
      copyMem(addr dest[pos], addr s.buf[0], count)
      s.buf.shift(count)
      pos += count

    if pos < nbytes:
      s.buf = await s.readHandler()
      if s.buf.len() == 0:
        raise newLPStreamIncompleteError()

method readOnce*(s: SimpleStream,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async.} =
  ## Perform one read operation on read-only stream ``rstream``.
  ##
  ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
  ## internal buffer, otherwise it will wait until some bytes will be received.
  ##
  if s.buf.len == 0:
    s.buf = await s.readHandler()

  let count = min(nbytes, s.buf.len())
  copyMem(pbytes, addr s.buf[0], count)
  s.buf.shift(count)
  return count

method write*(s: SimpleStream,
              pbytes: pointer,
              nbytes: int) {.async.} =
  ## Consume (discard) all bytes (n <= 0) or ``n`` bytes from read-only stream
  ## ``rstream``.
  ##
  ## Return number of bytes actually consumed (discarded).
  ##
  if isNil(s.writeHandler):
    raise newNotWritableError()

  var buf: seq[byte] = newSeq[byte](nbytes)
  copyMem(addr buf[0], pbytes, nbytes)
  await s.writeHandler(buf)

method write*(s: SimpleStream,
              msg: string,
              msglen = -1): Future[void] =
  ## Write string ``sbytes`` of length ``msglen`` to writer stream ``wstream``.
  ##
  ## String ``sbytes`` must not be zero-length.
  ##
  ## If ``msglen < 0`` whole string ``sbytes`` will be writen to stream.
  ## If ``msglen > len(sbytes)`` only ``len(sbytes)`` bytes will be written to
  ## stream.
  ##
  s.write(unsafeAddr msg[0], if msglen < 0: msg.len else: min(msg.len, msglen))

method write*(s: SimpleStream,
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
  s.write(unsafeAddr msg[0], if msglen < 0: msg.len else: min(msg.len, msglen))

method close*(s: SimpleStream) {.async.} =
  ## close the stream and clear the buffer
  s.buf.setLen(0)

  s.closeEvent.fire()
  s.isClosed = true

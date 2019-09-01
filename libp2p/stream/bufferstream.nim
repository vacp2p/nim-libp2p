## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import deques, tables, sequtils, math
import chronos
import ../stream/lpstream

## I use a dequeu here because it uses a ring buffer under the hood
## which should on average be more performant than memMoves and copies

type
  WriteHandler* = proc (data: seq[byte]) {.gcsafe.} # TODO: figure out how to make this generic to avoid casts

  BufferStream* = ref object of LPStream
    maxSize*: int
    readBuf: Deque[byte] # a deque is based on a ring buffer
    readReqs: Deque[Future[int]] # use dequeue to fire reads in order
    dataReadEvent: AsyncEvent
    writeHandler: WriteHandler

proc requestReadBytes(s: BufferStream): Future[int] = 
  ## create a future that will complete when more 
  ## data becomes available in the read buffer
  result = newFuture[int]()
  s.readReqs.addLast(result)

proc newBufferStream*(handler: WriteHandler, size: int = 1024): BufferStream =
  new result
  result.maxSize = if isPowerOfTwo(size): size else: nextPowerOfTwo(size)
  result.readBuf = initDeque[byte](result.maxSize)
  result.readReqs = initDeque[Future[int]]()
  result.dataReadEvent = newAsyncEvent()
  result.writeHandler = handler

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

proc pushTo*(s: BufferStream, data: seq[byte]) {.async, gcsafe.} =
  ## Write bytes to internal read buffer, use this to fill up the 
  ## buffer with data.
  ##
  ## This method is async and will wait until  all data has been 
  ## written to the internal buffer; this is done so that backpressure
  ## is preserved.
  var index = 0
  while true:
    while index < data.len and s.readBuf.len < s.maxSize:
      s.readBuf.addLast(data[index])
      inc(index)

    # resolve the next queued read request
    if s.readReqs.len > 0:
      s.readReqs.popFirst().complete(index + 1)
    
    if index >= data.len:
      break
  
    # if we couldn't transfer all the data to the 
    # internal buf do an async sleep and try writting 
    # some more, this should preserve backpresure
    await s.dataReadEvent.wait()

method read*(s: BufferStream, n = -1): Future[seq[byte]] {.async, gcsafe.} =
  ## Read all bytes (n <= 0) or exactly `n` bytes from buffer
  ##
  ## This procedure allocates buffer seq[byte] and return it as result.
  var size = if n > 0: n else: s.readBuf.len()
  var index = 0
  while index < size:
    while s.readBuf.len() > 0 and index < size:
      result.add(s.popFirst())
      inc(index)

    if index < size:
      discard await s.requestReadBytes()

method readExactly*(s: BufferStream, pbytes: pointer, nbytes: int): Future[void] {.async, gcsafe.} =
  ## Read exactly ``nbytes`` bytes from read-only stream ``rstream`` and store
  ## it to ``pbytes``.
  ##
  ## If EOF is received and ``nbytes`` is not yet readed, the procedure
  ## will raise ``LPStreamIncompleteError``.
  if nbytes > s.readBuf.len():
    raise newLPStreamIncompleteError()

  let buff = await s.read(nbytes)
  copyMem(pbytes, unsafeAddr buff[0], nbytes)

method readLine*(s: BufferStream, limit = 0, sep = "\r\n"): Future[string] {.async, gcsafe.} =
  ## Read one line from read-only stream ``rstream``, where ``"line"`` is a
  ## sequence of bytes ending with ``sep`` (default is ``"\r\n"``).
  ##
  ## If EOF is received, and ``sep`` was not found, the method will return the
  ## partial read bytes.
  ##
  ## If the EOF was received and the internal buffer is empty, return an
  ## empty string.
  ##
  ## If ``limit`` more then 0, then result string will be limited to ``limit``
  ## bytes.
  result = ""
  var lim = if limit <= 0: -1 else: limit
  var state = 0
  var index = 0

  index = 0
  while index < s.readBuf.len:
    let ch = char(s.readBuf[index])
    if sep[state] == ch:
      inc(state)
      if state == len(sep):
        s.shrink(index + 1)
        break
    else:
      state = 0
      result.add(ch)
      if len(result) == lim:
        s.shrink(index + 1)
        break
    inc(index)

method readOnce*(s: BufferStream, pbytes: pointer, nbytes: int): Future[int] {.async, gcsafe.} =
  ## Perform one read operation on read-only stream ``rstream``.
  ##
  ## If internal buffer is not empty, ``nbytes`` bytes will be transferred from
  ## internal buffer, otherwise it will wait until some bytes will be received.
  if s.readBuf.len == 0:
    discard await s.requestReadBytes()
  
  var len = if nbytes > s.readBuf.len: s.readBuf.len else: nbytes
  await s.readExactly(pbytes, len)
  result = len

method readUntil*(s: BufferStream,
                  pbytes: pointer, 
                  nbytes: int,
                  sep: seq[byte]): 
                  Future[int] {.async, gcsafe.} =
  ## Read data from the read-only stream ``rstream`` until separator ``sep`` is
  ## found.
  ##
  ## On success, the data and separator will be removed from the internal
  ## buffer (consumed). Returned data will include the separator at the end.
  ##
  ## If EOF is received, and `sep` was not found, procedure will raise
  ## ``LPStreamIncompleteError``.
  ##
  ## If ``nbytes`` bytes has been received and `sep` was not found, procedure
  ## will raise ``LPStreamLimitError``.
  ##
  ## Procedure returns actual number of bytes read.
  var
    dest = cast[ptr UncheckedArray[byte]](pbytes)
    state = 0
    k = 0

  let datalen = s.readBuf.len()
  if datalen == 0 and s.readBuf.len() == 0:
    raise newLPStreamIncompleteError()

  var index = 0
  while index < datalen:
    let ch = s.readBuf[index]
    if sep[state] == ch:
      inc(state)
    else:
      state = 0
    if k < nbytes:
      dest[k] = ch
      inc(k)
    else:
      raise newLPStreamLimitError()
    if state == len(sep):
      break
    inc(index)

  if state == len(sep):
    s.shrink(index + 1)
    result = k
  else:
    s.shrink(datalen)

method write*(s: BufferStream, pbytes: pointer, nbytes: int) {.async, gcsafe.} =
  var buf: seq[byte] = newSeq[byte](nbytes)
  copyMem(addr buf[0], pbytes, nbytes)
  s.writeHandler(buf)

method write*(s: BufferStream, msg: string, msglen = -1) {.async, gcsafe.} =
  var buf = ""
  shallowCopy(buf, if msglen > 0: msg[0..<msglen] else: msg)
  s.writeHandler(cast[seq[byte]](toSeq(buf.items)))

method write*(s: BufferStream, msg: seq[byte], msglen = -1) {.async, gcsafe.} =
  var buf: seq[byte]
  shallowCopy(buf, if msglen > 0: msg[0..<msglen] else: msg)
  s.writeHandler(buf)

method close*(s: BufferStream) {.async, gcsafe.} =
  for r in s.readReqs:
    r.cancel()
  s.readBuf.clear()
  s.closed = true

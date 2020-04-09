## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles
import peerinfo,
       multiaddress,
       stream/lpstream,
       peerinfo,
       varint,
       vbuffer

logScope:
  topic = "Connection"

const DefaultReadSize* = 1 shl 20

type
  Connection* = ref object of LPStream
    peerInfo*: PeerInfo
    stream*: LPStream
    observedAddrs*: Multiaddress

  InvalidVarintException = object of LPStreamError
  InvalidVarintSizeException = object of LPStreamError

proc newInvalidVarintException*(): ref InvalidVarintException =
  newException(InvalidVarintException, "Unable to parse varint")

proc newInvalidVarintSizeException*(): ref InvalidVarintSizeException =
  newException(InvalidVarintSizeException, "Wrong varint size")

proc bindStreamClose(conn: Connection) {.async.} =
  # bind stream's close event to connection's close
  # to ensure correct close propagation
  if not isNil(conn.stream.closeEvent):
    await conn.stream.closeEvent.wait()
    trace "wrapped stream closed, about to close conn", closed = conn.isClosed,
                                                        peer = if not isNil(conn.peerInfo):
                                                          conn.peerInfo.id else: ""
    if not conn.isClosed:
      trace "wrapped stream closed, closing conn", closed = conn.isClosed,
                                                    peer = if not isNil(conn.peerInfo):
                                                      conn.peerInfo.id else: ""
      asyncCheck conn.close()

proc init*[T: Connection](self: var T, stream: LPStream): T =
  ## create a new Connection for the specified async reader/writer
  new self
  self.stream = stream
  self.closeEvent = newAsyncEvent()
  asyncCheck self.bindStreamClose()

  return self

proc newConnection*(stream: LPStream): Connection =
  ## create a new Connection for the specified async reader/writer
  result.init(stream)

method read*(s: Connection, n = -1): Future[seq[byte]] {.gcsafe.} =
 s.stream.read(n)

method readExactly*(s: Connection,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] {.gcsafe.} =
 s.stream.readExactly(pbytes, nbytes)

method readLine*(s: Connection,
                 limit = 0,
                 sep = "\r\n"):
                 Future[string] {.gcsafe.} =
  s.stream.readLine(limit, sep)

method readOnce*(s: Connection,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.gcsafe.} =
  s.stream.readOnce(pbytes, nbytes)

method readUntil*(s: Connection,
                  pbytes: pointer,
                  nbytes: int,
                  sep: seq[byte]):
                  Future[int] {.gcsafe.} =
  s.stream.readUntil(pbytes, nbytes, sep)

method write*(s: Connection,
              pbytes: pointer,
              nbytes: int):
              Future[void] {.gcsafe.} =
  s.stream.write(pbytes, nbytes)

method write*(s: Connection,
              msg: string,
              msglen = -1):
              Future[void] {.gcsafe.} =
  s.stream.write(msg, msglen)

method write*(s: Connection,
              msg: seq[byte],
              msglen = -1):
              Future[void] {.gcsafe.} =
  s.stream.write(msg, msglen)

method closed*(s: Connection): bool =
  if isNil(s.stream):
    return false

  result = s.stream.closed

method close*(s: Connection) {.async, gcsafe.} =
  trace "about to close connection", closed = s.closed,
                                     peer = if not isNil(s.peerInfo):
                                       s.peerInfo.id else: ""

  if not s.closed:
    if not isNil(s.stream) and not s.stream.closed:
      trace "closing child stream", closed = s.closed,
                                    peer = if not isNil(s.peerInfo):
                                      s.peerInfo.id else: ""
      await s.stream.close()

    s.closeEvent.fire()
    s.isClosed = true

  trace "connection closed", closed = s.closed,
                             peer = if not isNil(s.peerInfo):
                               s.peerInfo.id else: ""

proc readLp*(s: Connection): Future[seq[byte]] {.async, gcsafe.} =
  ## read lenght prefixed msg
  var
    size: uint
    length: int
    res: VarintStatus
    buff = newSeq[byte](10)
  try:
    for i in 0..<len(buff):
      await s.readExactly(addr buff[i], 1)
      res = LP.getUVarint(buff.toOpenArray(0, i), length, size)
      if res == VarintStatus.Success:
        break
    if res != VarintStatus.Success:
      raise newInvalidVarintException()
    if size.int > DefaultReadSize:
      raise newInvalidVarintSizeException()
    buff.setLen(size)
    if size > 0.uint:
      trace "reading exact bytes from stream", size = size
      await s.readExactly(addr buff[0], int(size))
    return buff
  except LPStreamIncompleteError as exc:
    trace "remote connection ended unexpectedly", exc = exc.msg
    raise exc
  except LPStreamReadError as exc:
    trace "couldn't read from stream", exc = exc.msg
    raise exc

proc writeLp*(s: Connection, msg: string | seq[byte]): Future[void] {.gcsafe.} =
  ## write lenght prefixed
  var buf = initVBuffer()
  buf.writeSeq(msg)
  buf.finish()
  s.write(buf.buffer)

method getObservedAddrs*(c: Connection): Future[MultiAddress] {.base, async, gcsafe.} =
  ## get resolved multiaddresses for the connection
  result = c.observedAddrs

proc `$`*(conn: Connection): string =
  if not isNil(conn.peerInfo):
    result = $(conn.peerInfo)

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

const DefaultReadSize*: uint = 64 * 1024

type
  Connection* = ref object of LPStream
    peerInfo*: PeerInfo
    stream*: LPStream
    observedAddrs*: Multiaddress

  InvalidVarintException = object of LPStreamError

proc newInvalidVarintException*(): ref InvalidVarintException =
  newException(InvalidVarintException, "unable to prase varint")

proc newConnection*(stream: LPStream): Connection =
  ## create a new Connection for the specified async reader/writer
  new result
  result.stream = stream
  result.closeEvent = newAsyncEvent()

  # bind stream's close event to connection's close
  # to ensure correct close propagation
  let this = result
  if not isNil(result.stream.closeEvent):
    result.stream.closeEvent.wait().
      addCallback(
        proc (udata: pointer) =
          if not this.closed:
            trace "closing this connection because wrapped stream closed"
            asyncCheck this.close()
      )

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
  trace "closing connection"
  if not s.closed:
    if not isNil(s.stream) and not s.stream.closed:
      await s.stream.close()
    s.closeEvent.fire()
    s.isClosed = true
  trace "connection closed", closed = s.closed

proc readLp*(s: Connection): Future[seq[byte]] {.async, gcsafe.} =
  ## read lenght prefixed msg
  var
    size: uint
    length: int
    res: VarintStatus
  result = newSeq[byte](10)
  try:
    for i in 0..<len(result):
      await s.readExactly(addr result[i], 1)
      res = LP.getUVarint(result.toOpenArray(0, i), length, size)
      if res == VarintStatus.Success:
        break
    if res != VarintStatus.Success or size > DefaultReadSize:
      raise newInvalidVarintException()
    result.setLen(size)
    if size > 0.uint:
      trace "reading exact bytes from stream", size = size
      await s.readExactly(addr result[0], int(size))
  except LPStreamIncompleteError as exc:
    trace "remote connection ended unexpectedly", exc = exc.msg
  except LPStreamReadError as exc:
    trace "couldn't read from stream", exc = exc.msg

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
  result = $(conn.peerInfo)

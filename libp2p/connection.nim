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
       vbuffer

export lpstream

logScope:
  topic = "Connection"

const DefaultReadSize* = 1 shl 20

type
  Connection* = ref object of LPStream
    peerInfo*: PeerInfo
    stream*: LPStream
    observedAddrs*: Multiaddress

    sb*: StreamBuffer

  InvalidVarintException = object of LPStreamError
  InvalidVarintSizeException = object of LPStreamError

proc newInvalidVarintException*(): ref InvalidVarintException =
  newException(InvalidVarintException, "Unable to parse varint")

proc newInvalidVarintSizeException*(): ref InvalidVarintSizeException =
  newException(InvalidVarintSizeException, "Wrong varint size")

proc init*[T: Connection](self: var T, stream: LPStream) =
  ## create a new Connection for the specified async reader/writer
  doAssert not stream.isNil, "not nil life is easier"

  new self
  initLPStream(self)

  self.stream = stream
  self.sb = buffer(stream) # TODO it's now unsafe to read from raw stream!

  # bind stream's close event to connection's close
  # to ensure correct close propagation
  let this = self
  if not isNil(self.stream.closeEvent):
    self.stream.closeEvent.wait().
      addCallback do (udata: pointer):
        if not this.closed:
          trace "wrapped stream closed, closing conn"
          asyncCheck this.close()

proc newConnection*(stream: LPStream): Connection =
  ## create a new Connection for the specified async reader/writer
  result.init(stream)

method readOnce*(s: Connection): Future[seq[byte]] {.gcsafe.} =
  s.sb.readOnce()

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
    if not s.stream.closed:
      await s.stream.close()
    await procCall close(LPStream(s))

  trace "connection closed", closed = s.closed

proc readLp*(s: Connection, maxLen: int): Future[seq[byte]] {.async, gcsafe.} =
  var tmp = await s.sb.readVarintMessage(maxLen)
  if tmp.isNone(): raise newLPStreamEOFError()
  return tmp.get()

proc readLp*(s: Connection): Future[seq[byte]] {.deprecated: "Unsafe, pass a max size!", gcsafe .} =
  s.readLp(1024*1024) # Arbitrary!

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

## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, strformat
import ../../stream/bufferstream, 
       ../../stream/lpstream, 
       ../../connection,
       nimcrypto/utils,
       types, coder

const DefaultChannelSize* = DefaultBufferSize * 64 # 64kb

type
  Channel* = ref object of BufferStream
    id*: int
    name*: string
    conn*: Connection
    initiator*: bool
    isReset*: bool
    closedLocal*: bool
    closedRemote*: bool
    handlerFuture*: Future[void]
    msgCode*: MessageType
    closeCode*: MessageType
    resetCode*: MessageType

proc newChannel*(id: int,
                 conn: Connection,
                 initiator: bool,
                 name: string = "",
                 size: int = DefaultChannelSize): Channel = 
  new result
  result.id = id
  result.name = name
  result.conn = conn
  result.initiator = initiator
  result.msgCode = if initiator: MessageType.MsgOut else: MessageType.MsgIn
  result.closeCode = if initiator: MessageType.CloseOut else: MessageType.CloseIn
  result.resetCode = if initiator: MessageType.ResetOut else: MessageType.ResetIn

  let chan = result
  proc writeHandler(data: seq[byte]): Future[void] {.async, gcsafe.} = 
    await conn.writeHeader(chan.id, chan.msgCode, data.len) # write header
    await conn.write(data)

  result.initBufferStream(writeHandler, size)

proc closeMessage(s: Channel) {.async, gcsafe.} =
  await s.conn.writeHeader(s.id, s.closeCode) # write header

proc closed*(s: Channel): bool = 
  s.closedLocal

proc closedByRemote*(s: Channel) {.async.} = 
  s.closedRemote = true

method close*(s: Channel) {.async, gcsafe.} =
  s.closedLocal = true
  await s.closeMessage()

proc resetMessage(s: Channel) {.async, gcsafe.} =
  await s.conn.writeHeader(s.id, s.resetCode)

proc resetByRemote*(s: Channel) {.async, gcsafe.} =
  await allFutures(s.close(), s.closedByRemote())
  s.isReset = true

proc reset*(s: Channel) {.async.} =
  await allFutures(s.resetMessage(), s.resetByRemote())

proc isReadEof(s: Channel): bool = 
  bool((s.closedRemote or s.closedLocal) and s.len() < 1)

proc pushTo*(s: Channel, data: seq[byte]): Future[void] {.gcsafe.} =
  if s.closedRemote:
    raise newLPStreamClosedError()
  result = procCall pushTo(BufferStream(s), data)

method read*(s: Channel, n = -1): Future[seq[byte]] {.gcsafe.} =
  if s.isReadEof():
    raise newLPStreamClosedError()
  result = procCall read(BufferStream(s), n)

method readExactly*(s: Channel, 
                    pbytes: pointer, 
                    nbytes: int): 
                    Future[void] {.gcsafe.} =
  if s.isReadEof():
    raise newLPStreamClosedError()
  result = procCall readExactly(BufferStream(s), pbytes, nbytes)

method readLine*(s: Channel,
                 limit = 0,
                 sep = "\r\n"):
                 Future[string] {.gcsafe.} =
  if s.isReadEof():
    raise newLPStreamClosedError()
  result = procCall readLine(BufferStream(s), limit, sep)

method readOnce*(s: Channel, 
                 pbytes: pointer, 
                 nbytes: int): 
                 Future[int] {.gcsafe.} =
  if s.isReadEof():
    raise newLPStreamClosedError()
  result = procCall readOnce(BufferStream(s), pbytes, nbytes)

method readUntil*(s: Channel,
                  pbytes: pointer, nbytes: int,
                  sep: seq[byte]): 
                  Future[int] {.gcsafe.} =
  if s.isReadEof():
    raise newLPStreamClosedError()
  result = procCall readOnce(BufferStream(s), pbytes, nbytes)

method write*(s: Channel,
              pbytes: pointer, 
              nbytes: int): Future[void] {.gcsafe.} =
  if s.closedLocal:
    raise newLPStreamClosedError()
  result = procCall write(BufferStream(s), pbytes, nbytes)

method write*(s: Channel, msg: string, msglen = -1) {.async, gcsafe.} =
  if s.closedLocal:
    raise newLPStreamClosedError()
  result = procCall write(BufferStream(s), msg, msglen)

method write*(s: Channel, msg: seq[byte], msglen = -1) {.async, gcsafe.} =
  if s.closedLocal:
    raise newLPStreamClosedError()
  result = procCall write(BufferStream(s), msg, msglen)

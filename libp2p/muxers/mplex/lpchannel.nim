## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import strformat
import chronos, chronicles
import types,
       coder,
       nimcrypto/utils,
       ../../stream/bufferstream,
       ../../stream/lpstream,
       ../../connection

logScope:
  topic = "mplex-channel"

const DefaultChannelSize* = DefaultBufferSize * 64 # 64kb

type
  LPChannel* = ref object of BufferStream
    id*: uint
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
    asyncLock: AsyncLock

proc newChannel*(id: uint,
                 conn: Connection,
                 initiator: bool,
                 name: string = "",
                 size: int = DefaultChannelSize): LPChannel = 
  new result
  result.id = id
  result.name = name
  result.conn = conn
  result.initiator = initiator
  result.msgCode = if initiator: MessageType.MsgOut else: MessageType.MsgIn
  result.closeCode = if initiator: MessageType.CloseOut else: MessageType.CloseIn
  result.resetCode = if initiator: MessageType.ResetOut else: MessageType.ResetIn
  result.asyncLock = newAsyncLock()

  let chan = result
  proc writeHandler(data: seq[byte]): Future[void] {.async, gcsafe.} = 
    # writes should happen in sequence
    await chan.asyncLock.acquire()
    info "writeHandler: sending data ", data = data.toHex(), id = chan.id
    await conn.writeMsg(chan.id, chan.msgCode, data) # write header
    chan.asyncLock.release()

  result.initBufferStream(writeHandler, size)

proc closeMessage(s: LPChannel) {.async, gcsafe.} =
  await s.conn.writeMsg(s.id, s.closeCode) # write header

proc closed*(s: LPChannel): bool = 
  s.closedLocal and s.closedLocal

proc closedByRemote*(s: LPChannel) {.async.} = 
  s.closedRemote = true

proc cleanUp*(s: LPChannel): Future[void] =
  result = procCall close(BufferStream(s))

method close*(s: LPChannel) {.async, gcsafe.} =
  s.closedLocal = true
  await s.closeMessage()

proc resetMessage(s: LPChannel) {.async, gcsafe.} =
  await s.conn.writeMsg(s.id, s.resetCode)

proc resetByRemote*(s: LPChannel) {.async, gcsafe.} =
  await allFutures(s.close(), s.closedByRemote())
  s.isReset = true

proc reset*(s: LPChannel) {.async.} =
  await allFutures(s.resetMessage(), s.resetByRemote())

proc isReadEof(s: LPChannel): bool = 
  bool((s.closedRemote or s.closedLocal) and s.len() < 1)

proc pushTo*(s: LPChannel, data: seq[byte]): Future[void] {.gcsafe.} =
  if s.closedRemote:
    raise newLPStreamClosedError()
  result = procCall pushTo(BufferStream(s), data)

method read*(s: LPChannel, n = -1): Future[seq[byte]] {.gcsafe.} =
  if s.isReadEof():
    raise newLPStreamClosedError()
  result = procCall read(BufferStream(s), n)

method readExactly*(s: LPChannel, 
                    pbytes: pointer, 
                    nbytes: int): 
                    Future[void] {.gcsafe.} =
  if s.isReadEof():
    raise newLPStreamClosedError()
  result = procCall readExactly(BufferStream(s), pbytes, nbytes)

method readLine*(s: LPChannel,
                 limit = 0,
                 sep = "\r\n"):
                 Future[string] {.gcsafe.} =
  if s.isReadEof():
    raise newLPStreamClosedError()
  result = procCall readLine(BufferStream(s), limit, sep)

method readOnce*(s: LPChannel, 
                 pbytes: pointer, 
                 nbytes: int): 
                 Future[int] {.gcsafe.} =
  if s.isReadEof():
    raise newLPStreamClosedError()
  result = procCall readOnce(BufferStream(s), pbytes, nbytes)

method readUntil*(s: LPChannel,
                  pbytes: pointer, nbytes: int,
                  sep: seq[byte]): 
                  Future[int] {.gcsafe.} =
  if s.isReadEof():
    raise newLPStreamClosedError()
  result = procCall readOnce(BufferStream(s), pbytes, nbytes)

method write*(s: LPChannel,
              pbytes: pointer, 
              nbytes: int): Future[void] {.gcsafe.} =
  if s.closedLocal:
    raise newLPStreamClosedError()
  result = procCall write(BufferStream(s), pbytes, nbytes)

method write*(s: LPChannel, msg: string, msglen = -1) {.async, gcsafe.} =
  if s.closedLocal:
    raise newLPStreamClosedError()
  result = procCall write(BufferStream(s), msg, msglen)

method write*(s: LPChannel, msg: seq[byte], msglen = -1) {.async, gcsafe.} =
  if s.closedLocal:
    raise newLPStreamClosedError()
  result = procCall write(BufferStream(s), msg, msglen)

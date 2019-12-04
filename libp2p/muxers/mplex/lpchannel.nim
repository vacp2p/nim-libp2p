## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles
import types,
       coder,
       nimcrypto/utils,
       ../../stream/bufferstream,
       ../../stream/lpstream,
       ../../connection

logScope:
  topic = "MplexChannel"

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
  proc writeHandler(data: seq[byte]): Future[void] {.async.} = 
    # writes should happen in sequence
    await chan.asyncLock.acquire()
    trace "sending data ", data = data.toHex(),
                           id = chan.id,
                           initiator = chan.initiator

    await conn.writeMsg(chan.id, chan.msgCode, data) # write header
    chan.asyncLock.release()

  result.initBufferStream(writeHandler, size)

proc closeMessage(s: LPChannel) {.async.} =
  await s.conn.writeMsg(s.id, s.closeCode) # write header

proc closedByRemote*(s: LPChannel) {.async.} = 
  s.closedRemote = true

proc cleanUp*(s: LPChannel): Future[void] =
  # method which calls the underlying buffer's `close` 
  # method used instead of `close` since it's overloaded to
  # simulate half-closed streams
  result = procCall close(BufferStream(s))

proc open*(s: LPChannel): Future[void] =
  s.conn.writeMsg(s.id, MessageType.New, s.name)

method close*(s: LPChannel) {.async, gcsafe.} =
  s.closedLocal = true
  await s.closeMessage()

proc resetMessage(s: LPChannel) {.async.} =
  await s.conn.writeMsg(s.id, s.resetCode)

proc resetByRemote*(s: LPChannel) {.async.} =
  await allFutures(s.close(), s.closedByRemote())
  s.isReset = true

proc reset*(s: LPChannel) {.async.} =
  await allFutures(s.resetMessage(), s.resetByRemote())

method closed*(s: LPChannel): bool =
  result = s.closedRemote and s.len == 0

proc pushTo*(s: LPChannel, data: seq[byte]): Future[void] =
  if s.closedRemote or s.isReset:
    raise newLPStreamClosedError()
  trace "pushing data to channel", data = data.toHex(), 
                                   id = s.id, 
                                   initiator = s.initiator

  result = procCall pushTo(BufferStream(s), data)

method read*(s: LPChannel, n = -1): Future[seq[byte]] =
  if s.closed or s.isReset:
    raise newLPStreamClosedError()

  result = procCall read(BufferStream(s), n)

method readExactly*(s: LPChannel,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] =
  if s.closed or s.isReset:
    raise newLPStreamClosedError()
  result = procCall readExactly(BufferStream(s), pbytes, nbytes)

method readLine*(s: LPChannel,
                 limit = 0,
                 sep = "\r\n"):
                 Future[string] =
  if s.closed or s.isReset:
    raise newLPStreamClosedError()
  result = procCall readLine(BufferStream(s), limit, sep)

method readOnce*(s: LPChannel, 
                 pbytes: pointer, 
                 nbytes: int): 
                 Future[int] =
  if s.closed or s.isReset:
    raise newLPStreamClosedError()
  result = procCall readOnce(BufferStream(s), pbytes, nbytes)

method readUntil*(s: LPChannel,
                  pbytes: pointer, nbytes: int,
                  sep: seq[byte]): 
                  Future[int] =
  if s.closed or s.isReset:
    raise newLPStreamClosedError()
  result = procCall readOnce(BufferStream(s), pbytes, nbytes)

method write*(s: LPChannel,
              pbytes: pointer, 
              nbytes: int): Future[void] =
  if s.closedLocal or s.isReset:
    raise newLPStreamClosedError()
  result = procCall write(BufferStream(s), pbytes, nbytes)

method write*(s: LPChannel, msg: string, msglen = -1) {.async.} =
  if s.closedLocal or s.isReset:
    raise newLPStreamClosedError()
  result = procCall write(BufferStream(s), msg, msglen)

method write*(s: LPChannel, msg: seq[byte], msglen = -1) {.async.} =
  if s.closedLocal or s.isReset:
    raise newLPStreamClosedError()
  result = procCall write(BufferStream(s), msg, msglen)

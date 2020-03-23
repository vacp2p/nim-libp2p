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
       ../../connection,
       ../../utility

logScope:
  topic = "MplexChannel"

type
  LPChannel* = ref object of BufferStream
    id*: uint
    name*: string
    conn*: Connection
    initiator*: bool
    isLazy*: bool
    isOpen*: bool
    isReset*: bool
    closedLocal*: bool
    closedRemote*: bool
    handlerFuture*: Future[void]
    msgCode*: MessageType
    closeCode*: MessageType
    resetCode*: MessageType

proc newChannel*(id: uint,
                 conn: Connection,
                 initiator: bool,
                 name: string = "",
                 size: int = DefaultChannelSize,
                 lazy: bool = false): LPChannel =
  new result
  result.id = id
  result.name = name
  result.conn = conn
  result.initiator = initiator
  result.msgCode = if initiator: MessageType.MsgOut else: MessageType.MsgIn
  result.closeCode = if initiator: MessageType.CloseOut else: MessageType.CloseIn
  result.resetCode = if initiator: MessageType.ResetOut else: MessageType.ResetIn
  result.isLazy = lazy

  let chan = result
  proc writeHandler(data: seq[byte]): Future[void] {.async.} =
    # writes should happen in sequence
    trace "sending data ", data = data.shortLog,
                           id = chan.id,
                           initiator = chan.initiator

    await conn.writeMsg(chan.id, chan.msgCode, data) # write header

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
  s.isOpen = true
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
    var retFuture = newFuture[void]("LPChannel.pushTo")
    retFuture.fail(newLPStreamEOFError())
    return retFuture

  trace "pushing data to channel", data = data.shortLog,
                                   id = s.id,
                                   initiator = s.initiator

  result = procCall pushTo(BufferStream(s), data)

method read*(s: LPChannel, n = -1): Future[seq[byte]] =
  if s.closed or s.isReset:
    var retFuture = newFuture[seq[byte]]("LPChannel.read")
    retFuture.fail(newLPStreamEOFError())
    return retFuture

  result = procCall read(BufferStream(s), n)

method readExactly*(s: LPChannel,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] =
  if s.closed or s.isReset:
    var retFuture = newFuture[void]("LPChannel.readExactly")
    retFuture.fail(newLPStreamEOFError())
    return retFuture

  result = procCall readExactly(BufferStream(s), pbytes, nbytes)

method readLine*(s: LPChannel,
                 limit = 0,
                 sep = "\r\n"):
                 Future[string] =
  if s.closed or s.isReset:
    var retFuture = newFuture[string]("LPChannel.readLine")
    retFuture.fail(newLPStreamEOFError())
    return retFuture

  result = procCall readLine(BufferStream(s), limit, sep)

method readOnce*(s: LPChannel,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] =
  if s.closed or s.isReset:
    var retFuture = newFuture[int]("LPChannel.readOnce")
    retFuture.fail(newLPStreamEOFError())
    return retFuture

  result = procCall readOnce(BufferStream(s), pbytes, nbytes)

method readUntil*(s: LPChannel,
                  pbytes: pointer, nbytes: int,
                  sep: seq[byte]):
                  Future[int] =
  if s.closed or s.isReset:
    var retFuture = newFuture[int]("LPChannel.readUntil")
    retFuture.fail(newLPStreamEOFError())
    return retFuture

  result = procCall readOnce(BufferStream(s), pbytes, nbytes)

template writePrefix: untyped =
  if s.isLazy and not s.isOpen:
    await s.open()
  if s.closedLocal or s.isReset:
    raise newLPStreamEOFError()

method write*(s: LPChannel, pbytes: pointer, nbytes: int) {.async.} =
  writePrefix()
  await procCall write(BufferStream(s), pbytes, nbytes)

method write*(s: LPChannel, msg: string, msglen = -1) {.async.} =
  writePrefix()
  await procCall write(BufferStream(s), msg, msglen)

method write*(s: LPChannel, msg: seq[byte], msglen = -1) {.async.} =
  writePrefix()
  await procCall write(BufferStream(s), msg, msglen)

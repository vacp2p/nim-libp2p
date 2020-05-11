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
       ../../utility,
       ../../errors

export lpstream

logScope:
  topic = "MplexChannel"

const DefaultChannelSize* = 1 shl 20

type
  LPChannel* = ref object of BufferStream
    id*: uint64                   # channel id
    name*: string                 # name of the channel (for debugging)
    conn*: Connection             # wrapped connection used to for writing
    initiator*: bool              # initiated remotely or locally flag
    isLazy*: bool                 # is channel lazy
    isOpen*: bool                 # has channel been oppened (only used with isLazy)
    isReset*: bool                # has channel been reset
    closedLocal*: bool            # has channel been closed locally
    closedRemote*: bool           # has channel been closed remotely
    msgCode*: MessageType         # cached in/out message code
    closeCode*: MessageType       # cached in/out close code
    resetCode*: MessageType       # cached in/out reset code
    resetLock*: AsyncLock

proc newChannel*(id: uint64,
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

proc cleanUp*(s: LPChannel): Future[void] =
  # method which calls the underlying buffer's `close`
  # method used instead of `close` since it's overloaded to
  # simulate half-closed streams
  result = procCall close(BufferStream(s))

proc tryCleanup(s: LPChannel) {.async, inline.} =
  # if stream is EOF, then cleanup immediatelly
  if s.closedRemote and s.len == 0:
    await s.cleanUp()

proc closedByRemote*(s: LPChannel) {.async.} =
  s.closedRemote = true
  if s.len == 0:
    await s.cleanUp()

proc open*(s: LPChannel): Future[void] =
  s.isOpen = true
  s.conn.writeMsg(s.id, MessageType.New, s.name)

method close*(s: LPChannel) {.async, gcsafe.} =
  s.closedLocal = true
  await s.closeMessage()

proc resetMessage(s: LPChannel) {.async.} =
  await s.conn.writeMsg(s.id, s.resetCode)

proc resetByRemote*(s: LPChannel) {.async.} =
  # Immediately block futher calls
  s.isReset = true

  # start and await async teardown
  let
    futs = await allFinished(
      s.close(),
      s.closedByRemote(),
      s.cleanUp()
    )

  checkFutures(futs, [LPStreamEOFError])

proc reset*(s: LPChannel) {.async.} =
  let
    futs = await allFinished(
      s.resetMessage(),
      s.resetByRemote()
    )

  checkFutures(futs, [LPStreamEOFError])

method closed*(s: LPChannel): bool =
  trace "closing lpchannel", id = s.id, initiator = s.initiator
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

template raiseEOF(): untyped =
  if s.closed or s.isReset:
    raise newLPStreamEOFError()

method readExactly*(s: LPChannel,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] {.async.} =
  raiseEOF()
  await procCall readExactly(BufferStream(s), pbytes, nbytes)
  await s.tryCleanup()

method readOnce*(s: LPChannel,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async.} =
  raiseEOF()
  result = await procCall readOnce(BufferStream(s), pbytes, nbytes)
  await s.tryCleanup()

method write*(s: LPChannel, msg: seq[byte]) {.async.} =
  if s.closedLocal or s.isReset:
    raise newLPStreamEOFError()

  if s.isLazy and not s.isOpen:
    await s.open()

  await procCall write(BufferStream(s), msg)

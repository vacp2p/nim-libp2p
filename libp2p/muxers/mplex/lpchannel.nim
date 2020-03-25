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
       ../../stream/lpstream,
       ../../connection,
       ../../utility

logScope:
  topic = "MplexChannel"

type
  LPChannel* = ref object of LPStream
    id*: uint64
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
    queue*: AsyncQueue[seq[byte]]

proc newChannel*(id: uint64,
                 conn: Connection,
                 initiator: bool,
                 name: string = "",
                 lazy: bool = false): LPChannel =
  new result
  initLPStream(result)
  result.id = id
  result.name = name
  result.conn = conn
  result.initiator = initiator
  result.msgCode = if initiator: MessageType.MsgOut else: MessageType.MsgIn
  result.closeCode = if initiator: MessageType.CloseOut else: MessageType.CloseIn
  result.resetCode = if initiator: MessageType.ResetOut else: MessageType.ResetIn
  result.isLazy = lazy
  result.queue = newAsyncQueue[seq[byte]](1)

proc closeMessage(s: LPChannel) {.async.} =
  await s.conn.writeMsg(s.id, s.closeCode) # write header

proc cleanUp*(s: LPChannel): Future[void] =
  # method which calls the underlying buffer's `close`
  # method used instead of `close` since it's overloaded to
  # simulate half-closed streams
  result = procCall close(LPStream(s))

proc tryCleanup(s: LPChannel) {.async, inline.} =
  # if stream is EOF, then cleanup immediatelly
  if s.closedRemote and s.queue.len == 0:
    await s.cleanUp()

proc closedByRemote*(s: LPChannel) {.async.} =
  s.closedRemote = true
  if s.queue.len == 0:
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
  await allFutures(s.close(), s.closedByRemote())
  s.isReset = true
  await s.cleanUp()

proc reset*(s: LPChannel) {.async.} =
  await allFutures(s.resetMessage(), s.resetByRemote())

method closed*(s: LPChannel): bool =
  trace "closing lpchannel", id = s.id, initiator = s.initiator
  result = s.closedRemote and s.queue.len == 0

proc pushTo*(s: LPChannel, data: seq[byte]) {.async.} =
  if s.closedRemote or s.isReset:
    raise newLPStreamEOFError()

  trace "pushing data to channel", data = data.shortLog,
                                   id = s.id,
                                   initiator = s.initiator

  await s.queue.put(data)

template raiseEOF(): untyped =
  if s.closed or s.isReset:
    raise newLPStreamEOFError()

method readOnce*(s: LPChannel): Future[seq[byte]] {.gcsafe, async.} =
  raiseEOF()
  result = await s.queue.get()
  await s.tryCleanup()

template writePrefix: untyped =
  if s.closedLocal or s.isReset:
    raise newLPStreamEOFError()

  if s.isLazy and not s.isOpen:
    await s.open()

method write*(s: LPChannel, msg: seq[byte], msglen = -1) {.async.} =
  writePrefix()
  await s.conn.writeMsg(s.id, s.msgCode, msg)

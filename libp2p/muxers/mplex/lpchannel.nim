## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import oids, deques
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

## Channel half-closed states
##
## | State    | Closed local      | Closed remote
## |=============================================
## | Read     | Yes (until EOF)   | No
## | Write    | No	              | Yes
##

type
  LPChannel* = ref object of BufferStream
    id*: uint64                   # channel id
    name*: string                 # name of the channel (for debugging)
    conn*: Connection             # wrapped connection used to for writing
    initiator*: bool              # initiated remotely or locally flag
    isLazy*: bool                 # is channel lazy
    isOpen*: bool                 # has channel been oppened (only used with isLazy)
    closedLocal*: bool            # has channel been closed locally
    msgCode*: MessageType         # cached in/out message code
    closeCode*: MessageType       # cached in/out close code
    resetCode*: MessageType       # cached in/out reset code

proc open*(s: LPChannel) {.async, gcsafe.}

proc newChannel*(id: uint64,
                 conn: Connection,
                 initiator: bool,
                 name: string = "",
                 size: int = DefaultBufferSize,
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
  proc writeHandler(data: seq[byte]): Future[void] {.async, gcsafe.} =
    if chan.isLazy and not(chan.isOpen):
      await chan.open()

    # writes should happen in sequence
    trace "sending data", data = data.shortLog,
                          id = chan.id,
                          initiator = chan.initiator,
                          name = chan.name,
                          oid = chan.oid

    await conn.writeMsg(chan.id, chan.msgCode, data) # write header

  result.initBufferStream(writeHandler, size)
  when chronicles.enabledLogLevel == LogLevel.TRACE:
    result.name = if result.name.len > 0: result.name else: $result.oid

  trace "created new lpchannel", id = result.id,
                                 oid = result.oid,
                                 initiator = result.initiator,
                                 name = result.name

proc closeMessage(s: LPChannel) {.async.} =
  try:
    await s.writeLock.acquire()
    trace "sending close message", id = s.id,
                                   initiator = s.initiator,
                                   name = s.name,
                                   oid = s.oid

    await s.conn.writeMsg(s.id, s.closeCode) # write close
  except LPStreamEOFError as exc:
    trace "unable to send closed, muxed connection EOF", exc = exc.msg
  except LPStreamClosedError as exc:
    trace "unable to send close, muxed connection closed", exc = exc.msg
  except LPStreamIncompleteError as exc:
    trace "unable to send close, incomplete message", exc = exc.msg
  finally:
    s.writeLock.release()

proc resetMessage(s: LPChannel) {.async.} =
  try:
    await s.writeLock.acquire()
    trace "sending reset message", id = s.id,
                                   initiator = s.initiator,
                                   name = s.name,
                                   oid = s.oid

    await s.conn.writeMsg(s.id, s.resetCode) # write reset
  except LPStreamEOFError as exc:
    trace "unable to send reset, muxed connection EOF", exc = exc.msg
  except LPStreamClosedError as exc:
    trace "unable to send reset, muxed connection closed", exc = exc.msg
  except LPStreamIncompleteError as exc:
    trace "unable to send reset, incomplete message", exc = exc.msg
  finally:
    s.writeLock.release()

proc open*(s: LPChannel) {.async, gcsafe.} =
  await s.conn.writeMsg(s.id, MessageType.New, s.name)
  trace "oppened channel", oid = s.oid,
                           name = s.name,
                           initiator = s.initiator
  s.isOpen = true

proc closeRemote*(s: LPChannel) {.async.} =
  trace "got EOF, closing channel", id = s.id,
                                    initiator = s.initiator,
                                    name = s.name,
                                    oid = s.oid

  # wait for all data in the buffer to be consumed
  while s.len > 0:
    await s.dataReadEvent.wait()
    s.dataReadEvent.clear()

  # TODO: Not sure if this needs to be set here or bfore consuming
  # the buffer
  s.isEof = true # set EOF immediately to prevent further reads
  await procCall BufferStream(s).close() # close parent bufferstream

  trace "channel closed on EOF", id = s.id,
                                 initiator = s.initiator,
                                 oid = s.oid,
                                 name = s.name

method closed*(s: LPChannel): bool =
  ## this emulates half-closed behavior
  ## when closed locally writing is
  ## dissabled - see the table in the
  ## header of the file
  s.closedLocal

method close*(s: LPChannel) {.async, gcsafe.} =
  if s.closedLocal:
    return

  trace "closing local lpchannel", id = s.id,
                                   initiator = s.initiator,
                                   name = s.name,
                                   oid = s.oid
  await s.closeMessage()
  s.closedLocal = true
  if s.atEof: # already closed by remote close parent buffer imediately
    await procCall BufferStream(s).close()

  trace "lpchannel closed local", id = s.id,
                                  initiator = s.initiator,
                                  name = s.name,
                                  oid = s.oid

method reset*(s: LPChannel) {.base, async.} =
  # we asyncCheck here because the other end
  # might be dead already - reset is always
  # optimistic
  asyncCheck s.resetMessage()
  await procCall BufferStream(s).close()

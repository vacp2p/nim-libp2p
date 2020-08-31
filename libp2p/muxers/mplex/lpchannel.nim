## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import oids, deques
import chronos, chronicles, metrics
import types,
       coder,
       ../muxer,
       nimcrypto/utils,
       ../../stream/connection,
       ../../stream/bufferstream,
       ../../peerinfo

export connection

logScope:
  topics = "mplexchannel"

## Channel half-closed states
##
## | State    | Closed local      | Closed remote
## |=============================================
## | Read     | Yes (until EOF)   | No
## | Write    | No                | Yes
##

# TODO: this is one place where we need to use
# a proper state machine, but I've opted out of
# it for now for two reasons:
#
# 1) we don't have that many states to manage
# 2) I'm not sure if adding the state machine
# would have simplified or complicated the code
#
# But now that this is in place, we should perhaps
# reconsider reworking it again, this time with a
# more formal approach.
#

type
  LPChannel* = ref object of BufferStream
    id*: uint64                   # channel id
    name*: string                 # name of the channel (for debugging)
    conn*: Connection             # wrapped connection used to for writing
    initiator*: bool              # initiated remotely or locally flag
    isLazy*: bool                 # is channel lazy
    isOpen*: bool                 # has channel been opened (only used with isLazy)
    closedLocal*: bool            # has channel been closed locally
    msgCode*: MessageType         # cached in/out message code
    closeCode*: MessageType       # cached in/out close code
    resetCode*: MessageType       # cached in/out reset code

proc open*(s: LPChannel) {.async, gcsafe.}

template withWriteLock(lock: AsyncLock, body: untyped): untyped =
  try:
    await lock.acquire()
    body
  finally:
    if not(isNil(lock)) and lock.locked:
      lock.release()

proc closeMessage(s: LPChannel) {.async.} =
  logScope:
    id = s.id
    initiator = s.initiator
    name = s.name
    oid = $s.oid
    peer = $s.conn.peerInfo
    # stack = getStackTrace()

  ## send close message - this will not raise
  ## on EOF or Closed
  withWriteLock(s.writeLock):
    trace "sending close message"

    await s.conn.writeMsg(s.id, s.closeCode) # write close

proc resetMessage(s: LPChannel) {.async.} =
  logScope:
    id = s.id
    initiator = s.initiator
    name = s.name
    oid = $s.oid
    peer = $s.conn.peerInfo
    # stack = getStackTrace()

  ## send reset message - this will not raise
  try:
    withWriteLock(s.writeLock):
      trace "sending reset message"
      await s.conn.writeMsg(s.id, s.resetCode) # write reset
  except CancelledError:
    # This procedure is called from one place and never awaited, so there no
    # need to re-raise CancelledError.
    trace "Unexpected cancellation while resetting channel"
  except LPStreamEOFError as exc:
    trace "muxed connection EOF", exc = exc.msg
  except LPStreamClosedError as exc:
    trace "muxed connection closed", exc = exc.msg
  except LPStreamIncompleteError as exc:
    trace "incomplete message", exc = exc.msg
  except CatchableError as exc:
    trace "Unhandled exception leak", exc = exc.msg

proc open*(s: LPChannel) {.async, gcsafe.} =
  logScope:
    id = s.id
    initiator = s.initiator
    name = s.name
    oid = $s.oid
    peer = $s.conn.peerInfo
    # stack = getStackTrace()

  ## NOTE: Don't call withExcAndLock or withWriteLock,
  ## because this already gets called from writeHandler
  ## which is locked
  await s.conn.writeMsg(s.id, MessageType.New, s.name)
  trace "opened channel"
  s.isOpen = true

proc closeRemote*(s: LPChannel) {.async.} =
  logScope:
    id = s.id
    initiator = s.initiator
    name = s.name
    oid = $s.oid
    peer = $s.conn.peerInfo
    # stack = getStackTrace()

  trace "got EOF, closing channel"
  try:
    await s.drainBuffer()
    s.isEof = true # set EOF immediately to prevent further reads
    # close parent bufferstream to prevent further reads
    await procCall BufferStream(s).close()

    trace "channel closed on EOF"
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "exception closing remote channel", exc = exc.msg

method closed*(s: LPChannel): bool =
  ## this emulates half-closed behavior
  ## when closed locally writing is
  ## disabled - see the table in the
  ## header of the file
  s.closedLocal

method reset*(s: LPChannel) {.base, async, gcsafe.} =
  logScope:
    id = s.id
    initiator = s.initiator
    name = s.name
    oid = $s.oid
    peer = $s.conn.peerInfo
    # stack = getStackTrace()

  if s.closedLocal and s.isEof:
    trace "channel already closed or reset"
    return

  trace "resetting channel"

  discard s.resetMessage()

  try:
    # drain the buffer before closing
    await s.drainBuffer()
    await procCall BufferStream(s).close()

    s.isEof = true
    s.closedLocal = true

  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "exception in reset", exc = exc.msg

  trace "channel reset"

method close*(s: LPChannel) {.async, gcsafe.} =
  logScope:
    id = s.id
    initiator = s.initiator
    name = s.name
    oid = $s.oid
    peer = $s.conn.peerInfo
    # stack = getStackTrace()

  if s.closedLocal:
    trace "channel already closed"
    return

  trace "closing local lpchannel"

  proc closeInternal() {.async.} =
    try:
      await s.closeMessage().wait(2.minutes)
      if s.atEof: # already closed by remote close parent buffer immediately
        await procCall BufferStream(s).close()
    except CancelledError:
      trace "Unexpected cancellation while closing channel"
      await s.reset()
      # This is top-level procedure which will work as separate task, so it
      # do not need to propogate CancelledError.
    except CatchableError as exc:
      trace "exception closing channel", exc = exc.msg
      await s.reset()

    trace "lpchannel closed local"

  s.closedLocal = true
  # All the errors are handled inside `closeInternal()` procedure.
  discard closeInternal()

method initStream*(s: LPChannel) =
  if s.objName.len == 0:
    s.objName = "LPChannel"

  s.timeoutHandler = proc() {.async, gcsafe.} =
    trace "idle timeout expired, resetting LPChannel"
    await s.reset()

  procCall BufferStream(s).initStream()

proc init*(
  L: type LPChannel,
  id: uint64,
  conn: Connection,
  initiator: bool,
  name: string = "",
  size: int = DefaultBufferSize,
  lazy: bool = false,
  timeout: Duration = DefaultChanTimeout): LPChannel =

  let chann = L(
    id: id,
    name: name,
    conn: conn,
    initiator: initiator,
    isLazy: lazy,
    timeout: timeout,
    msgCode: if initiator: MessageType.MsgOut else: MessageType.MsgIn,
    closeCode: if initiator: MessageType.CloseOut else: MessageType.CloseIn,
    resetCode: if initiator: MessageType.ResetOut else: MessageType.ResetIn,
    dir: if initiator: Direction.Out else: Direction.In)

  logScope:
    id = chann.id
    initiator = chann.initiator
    name = chann.name
    oid = $chann.oid
    peer = $chann.conn.peerInfo
    # stack = getStackTrace()

  proc writeHandler(data: seq[byte]) {.async, gcsafe.} =
    try:
      if chann.isLazy and not(chann.isOpen):
        await chann.open()

      # writes should happen in sequence
      trace "sending data", len = data.len

      await conn.writeMsg(chann.id,
                          chann.msgCode,
                          data)
    except CatchableError as exc:
      trace "exception in lpchannel write handler", exc = exc.msg
      await chann.reset()
      raise exc

  chann.initBufferStream(writeHandler, size)
  when chronicles.enabledLogLevel == LogLevel.TRACE:
    chann.name = if chann.name.len > 0: chann.name else: $chann.oid

  trace "created new lpchannel"

  return chann

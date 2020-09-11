## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[oids, strformat]
import chronos, chronicles, metrics
import types,
       coder,
       ../muxer,
       nimcrypto/utils,
       ../../stream/[bufferstream, connection, streamseq],
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
    isReset*: bool                # channel was reset, pushTo should drop data
    pushing*: bool
    closedLocal*: bool            # has channel been closed locally
    msgCode*: MessageType         # cached in/out message code
    closeCode*: MessageType       # cached in/out close code
    resetCode*: MessageType       # cached in/out reset code
    writeLock: AsyncLock

proc open*(s: LPChannel) {.async, gcsafe.}

template withWriteLock(lock: AsyncLock, body: untyped): untyped =
  try:
    await lock.acquire()
    body
  finally:
    if not(isNil(lock)) and lock.locked:
      lock.release()

func shortLog*(s: LPChannel): auto =
  if s.isNil: "LPChannel(nil)"
  elif s.conn.peerInfo.isNil: $s.oid
  elif s.name != $s.oid: &"{shortLog(s.conn.peerInfo.peerId)}:{s.oid}:{s.name}"
  else: &"{shortLog(s.conn.peerInfo.peerId)}:{s.oid}"
chronicles.formatIt(LPChannel): shortLog(it)

proc closeMessage(s: LPChannel) {.async.} =
  ## send close message - this will not raise
  ## on EOF or Closed
  withWriteLock(s.writeLock):
    trace "sending close message", s

    await s.conn.writeMsg(s.id, s.closeCode) # write close

proc resetMessage(s: LPChannel) {.async.} =
  ## send reset message - this will not raise
  try:
    withWriteLock(s.writeLock):
      trace "sending reset message", s
      await s.conn.writeMsg(s.id, s.resetCode) # write reset
  except CancelledError:
    # This procedure is called from one place and never awaited, so there no
    # need to re-raise CancelledError.
    debug "Unexpected cancellation while resetting channel", s
  except LPStreamEOFError as exc:
    trace "muxed connection EOF", s, exc = exc.msg
  except LPStreamClosedError as exc:
    trace "muxed connection closed", s, exc = exc.msg
  except LPStreamIncompleteError as exc:
    trace "incomplete message", s, exc = exc.msg
  except CatchableError as exc:
    debug "Unhandled exception leak", s, exc = exc.msg

proc open*(s: LPChannel) {.async, gcsafe.} =
  await s.conn.writeMsg(s.id, MessageType.New, s.name)
  trace "Opened channel", s
  s.isOpen = true

proc closeRemote*(s: LPChannel) {.async.} =
  trace "Closing remote", s
  try:
    # close parent bufferstream to prevent further reads
    await procCall BufferStream(s).close()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "exception closing remote channel", s, exc = exc.msg

  trace "Closed remote", s

method closed*(s: LPChannel): bool =
  ## this emulates half-closed behavior
  ## when closed locally writing is
  ## disabled - see the table in the
  ## header of the file
  s.closedLocal

method pushTo*(s: LPChannel, data: seq[byte]) {.async.} =
  if s.isReset:
    raise newLPStreamClosedError() # Terminate mplex loop

  try:
    s.pushing = true
    await procCall BufferStream(s).pushTo(data)
  finally:
    s.pushing = false

method reset*(s: LPChannel) {.base, async, gcsafe.} =
  if s.closedLocal and s.isEof:
    trace "channel already closed or reset", s
    return

  trace "Resetting channel", s

  # First, make sure any new calls to `readOnce` and `pushTo` will fail - there
  # may already be such calls in the event queue
  s.isEof = true
  s.isReset = true

  s.readBuf = StreamSeq()

  s.closedLocal = true

  asyncSpawn s.resetMessage()

  # This should wake up any readers by pushing an EOF marker at least
  await procCall BufferStream(s).close() # noraises, nocancels

  if s.pushing:
    # When data is being pushed, there will be two items competing for the
    # readQueue slot - the BufferStream.close EOF marker and the pushTo data.
    # If the EOF wins, the pushTo call will get stuck because there will be no
    # new readers to clear the data. It's worth noting that if there's a reader
    # already waiting for data, this reader will be unblocked by the pushTo -
    # this is necessary or it will get stuck
    if s.readQueue.len > 0:
      discard s.readQueue.popFirstNoWait()

  trace "Channel reset", s

method close*(s: LPChannel) {.async, gcsafe.} =
  if s.closedLocal:
    trace "Already closed", s
    return

  trace "Closing channel", s

  proc closeInternal() {.async.} =
    try:
      await s.closeMessage().wait(2.minutes)
      if s.atEof: # already closed by remote close parent buffer immediately
        await procCall BufferStream(s).close()
    except CancelledError:
      debug "Unexpected cancellation while closing channel", s
      await s.reset()
      # This is top-level procedure which will work as separate task, so it
      # do not need to propogate CancelledError.
    except LPStreamClosedError, LPStreamEOFError:
      trace "Connection already closed", s
    except CatchableError as exc: # Shouldn't happen?
      debug "Exception closing channel", s, exc = exc.msg
      await s.reset()

    trace "Closed channel", s

  s.closedLocal = true
  # All the errors are handled inside `closeInternal()` procedure.
  asyncSpawn closeInternal()

method initStream*(s: LPChannel) =
  if s.objName.len == 0:
    s.objName = "LPChannel"

  s.timeoutHandler = proc(): Future[void] {.gcsafe.} =
    trace "Idle timeout expired, resetting LPChannel", s
    s.reset()

  procCall BufferStream(s).initStream()

  s.writeLock = newAsyncLock()

method write*(s: LPChannel, msg: seq[byte]): Future[void] {.async.} =
  if s.closedLocal:
    raise newLPStreamClosedError()

  try:
    if s.isLazy and not(s.isOpen):
      await s.open()

    # writes should happen in sequence
    trace "write msg", len = msg.len

    await s.conn.writeMsg(s.id, s.msgCode, msg)
    s.activity = true
  except CatchableError as exc:
    trace "exception in lpchannel write handler", s, exc = exc.msg
    await s.conn.close()
    raise exc

proc init*(
  L: type LPChannel,
  id: uint64,
  conn: Connection,
  initiator: bool,
  name: string = "",
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

  chann.initStream()

  when chronicles.enabledLogLevel == LogLevel.TRACE:
    chann.name = if chann.name.len > 0: chann.name else: $chann.oid

  trace "Created new lpchannel", chann

  return chann

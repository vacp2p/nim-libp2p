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
  topics = "MplexChannel"

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
    lock.release()

template withEOFExceptions(body: untyped): untyped =
  try:
      body
  except LPStreamEOFError as exc:
    trace "muxed connection EOF", exc = exc.msg
  except LPStreamClosedError as exc:
    trace "muxed connection closed", exc = exc.msg
  except LPStreamIncompleteError as exc:
    trace "incomplete message", exc = exc.msg

method reset*(s: LPChannel) {.base, async, gcsafe.}

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
    try:
      if chan.isLazy and not(chan.isOpen):
        await chan.open()

      # writes should happen in sequence
      trace "sending data", data = data.shortLog,
                            id = chan.id,
                            initiator = chan.initiator,
                            name = chan.name,
                            oid = chan.oid

      try:
        await conn.writeMsg(chan.id,
                            chan.msgCode,
                            data).wait(2.minutes) # write header
      except AsyncTimeoutError:
        trace "timeout writing channel, resetting"
        asyncCheck chan.reset()
    except CatchableError as exc:
      trace "unable to write in bufferstream handler", exc = exc.msg

  result.initBufferStream(writeHandler, size)
  when chronicles.enabledLogLevel == LogLevel.TRACE:
    result.name = if result.name.len > 0: result.name else: $result.oid

  trace "created new lpchannel", id = result.id,
                                 oid = result.oid,
                                 initiator = result.initiator,
                                 name = result.name

proc closeMessage(s: LPChannel) {.async.} =
  ## send close message - this will not raise
  ## on EOF or Closed
  withEOFExceptions:
    withWriteLock(s.writeLock):
      trace "sending close message", id = s.id,
                                     initiator = s.initiator,
                                     name = s.name,
                                     oid = s.oid

      await s.conn.writeMsg(s.id, s.closeCode) # write close

proc resetMessage(s: LPChannel) {.async.} =
  ## send reset message - this will not raise
  withEOFExceptions:
    withWriteLock(s.writeLock):
      trace "sending reset message", id = s.id,
                                     initiator = s.initiator,
                                     name = s.name,
                                     oid = s.oid

      await s.conn.writeMsg(s.id, s.resetCode) # write reset

proc open*(s: LPChannel) {.async, gcsafe.} =
  ## NOTE: Don't call withExcAndLock or withWriteLock,
  ## because this already gets called from writeHandler
  ## which is locked
  withEOFExceptions:
    await s.conn.writeMsg(s.id, MessageType.New, s.name)
    trace "opened channel", oid = s.oid,
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

  s.isEof = true # set EOF immediately to prevent further reads
  await s.close() # close local end
  # call to avoid leaks
  await procCall BufferStream(s).close() # close parent bufferstream

  trace "channel closed on EOF", id = s.id,
                                 initiator = s.initiator,
                                 oid = s.oid,
                                 name = s.name

method closed*(s: LPChannel): bool =
  ## this emulates half-closed behavior
  ## when closed locally writing is
  ## disabled - see the table in the
  ## header of the file
  s.closedLocal

method reset*(s: LPChannel) {.base, async, gcsafe.} =
  # we asyncCheck here because the other end
  # might be dead already - reset is always
  # optimistic
  asyncCheck s.resetMessage()
  await procCall BufferStream(s).close()
  s.isEof = true
  s.closedLocal = true

method close*(s: LPChannel) {.async, gcsafe.} =
  if s.closedLocal:
    trace "channel already closed", id = s.id,
                                    initiator = s.initiator,
                                    name = s.name,
                                    oid = s.oid
    return

  proc closeRemote() {.async.} =
    try:
      trace "closing local lpchannel", id = s.id,
                                       initiator = s.initiator,
                                       name = s.name,
                                       oid = s.oid
      await s.closeMessage().wait(2.minutes)
      s.closedLocal = true
      if s.atEof: # already closed by remote close parent buffer immediately
        await procCall BufferStream(s).close()
    except AsyncTimeoutError:
      trace "close timed out, reset channel"
      asyncCheck s.reset() # reset on timeout
    except CatchableError as exc:
      trace "exception closing channel"

    trace "lpchannel closed local", id = s.id,
                                    initiator = s.initiator,
                                    name = s.name,
                                    oid = s.oid

  asyncCheck closeRemote()

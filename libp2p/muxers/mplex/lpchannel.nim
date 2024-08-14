# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[oids, strformat]
import pkg/[chronos, chronicles, metrics]
import
  ./coder, ../muxer, ../../stream/[bufferstream, connection, streamseq], ../../peerinfo

export connection

logScope:
  topics = "libp2p mplexchannel"

when defined(libp2p_mplex_metrics):
  declareHistogram libp2p_mplex_qlen,
    "message queue length",
    buckets = [0.0, 1.0, 2.0, 4.0, 8.0, 16.0, 32.0, 64.0, 128.0, 256.0, 512.0]
  declareCounter libp2p_mplex_qlenclose, "closed because of max queuelen"
  declareHistogram libp2p_mplex_qtime, "message queuing time"

when defined(libp2p_network_protocols_metrics):
  declareCounter libp2p_protocols_bytes,
    "total sent or received bytes", ["protocol", "direction"]

## Channel half-closed states
##
## | State    | Closed local      | Closed remote
## |=============================================
## | Read     | Yes (until EOF)   | No
## | Write    | No                | Yes
##
## Channels are considered fully closed when both outgoing and incoming
## directions are closed and when the reader of the channel has read the
## EOF marker

const
  MaxWrites = 1024
    ##\
    ## Maximum number of in-flight writes - after this, we disconnect the peer

  LPChannelTrackerName* = "LPChannel"

type LPChannel* = ref object of BufferStream
  id*: uint64 # channel id
  name*: string # name of the channel (for debugging)
  conn*: Connection # wrapped connection used to for writing
  initiator*: bool # initiated remotely or locally flag
  isOpen*: bool # has channel been opened
  closedLocal*: bool # has channel been closed locally
  remoteReset*: bool # has channel been remotely reset
  localReset*: bool # has channel been reset locally
  msgCode*: MessageType # cached in/out message code
  closeCode*: MessageType # cached in/out close code
  resetCode*: MessageType # cached in/out reset code
  writes*: int # In-flight writes

func shortLog*(s: LPChannel): auto =
  try:
    if s == nil:
      "LPChannel(nil)"
    elif s.name != $s.oid and s.name.len > 0:
      &"{shortLog(s.conn.peerId)}:{s.oid}:{s.name}"
    else:
      &"{shortLog(s.conn.peerId)}:{s.oid}"
  except ValueError as exc:
    raiseAssert(exc.msg)

chronicles.formatIt(LPChannel):
  shortLog(it)

proc open*(s: LPChannel) {.async: (raises: [CancelledError, LPStreamError]).} =
  trace "Opening channel", s, conn = s.conn
  if s.conn.isClosed:
    return
  try:
    await s.conn.writeMsg(s.id, MessageType.New, s.name)
    s.isOpen = true
  except CancelledError as exc:
    raise exc
  except LPStreamError as exc:
    await s.conn.close()
    raise exc

method closed*(s: LPChannel): bool =
  s.closedLocal

proc closeUnderlying(s: LPChannel): Future[void] {.async: (raises: []).} =
  ## Channels may be closed for reading and writing in any order - we'll close
  ## the underlying bufferstream when both directions are closed
  if s.closedLocal and s.atEof():
    await procCall BufferStream(s).close()

proc reset*(s: LPChannel) {.async: (raises: []).} =
  if s.isClosed:
    trace "Already closed", s
    return

  s.isClosed = true
  s.closedLocal = true
  s.localReset = not s.remoteReset

  trace "Resetting channel", s, len = s.len

  if s.isOpen and not s.conn.isClosed:
    # If the connection is still active, notify the other end
    proc resetMessage() {.async: (raises: []).} =
      try:
        trace "sending reset message", s, conn = s.conn
        await noCancel s.conn.writeMsg(s.id, s.resetCode) # write reset
      except LPStreamError as exc:
        trace "Can't send reset message", s, conn = s.conn, description = exc.msg
        await s.conn.close()

    asyncSpawn resetMessage()

  await s.closeImpl()

  trace "Channel reset", s

method close*(s: LPChannel) {.async: (raises: []).} =
  ## Close channel for writing - a message will be sent to the other peer
  ## informing them that the channel is closed and that we're waiting for
  ## their acknowledgement.
  if s.closedLocal:
    trace "Already closed", s
    return
  s.closedLocal = true

  trace "Closing channel", s, conn = s.conn, len = s.len

  if s.isOpen and not s.conn.isClosed:
    try:
      await s.conn.writeMsg(s.id, s.closeCode) # write close
    except CancelledError:
      await s.conn.close()
    except LPStreamError as exc:
      # It's harmless that close message cannot be sent - the connection is
      # likely down already
      await s.conn.close()
      trace "Cannot send close message", s, id = s.id, description = exc.msg

  await s.closeUnderlying() # maybe already eofed

  trace "Closed channel", s, len = s.len

method initStream*(s: LPChannel) =
  if s.objName.len == 0:
    s.objName = LPChannelTrackerName

  s.timeoutHandler = proc(): Future[void] {.async: (raises: [], raw: true).} =
    trace "Idle timeout expired, resetting LPChannel", s
    s.reset()

  procCall BufferStream(s).initStream()

method readOnce*(
    s: LPChannel, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Mplex relies on reading being done regularly from every channel, or all
  ## channels are blocked - in particular, this means that reading from one
  ## channel must not be done from within a callback / read handler of another
  ## or the reads will lock each other.
  if s.remoteReset:
    raise newLPStreamResetError()
  if s.localReset:
    raise newLPStreamClosedError()
  if s.atEof():
    raise newLPStreamRemoteClosedError()
  if s.conn.closed:
    raise newLPStreamConnDownError()
  try:
    let bytes = await procCall BufferStream(s).readOnce(pbytes, nbytes)
    when defined(libp2p_network_protocols_metrics):
      if s.protocol.len > 0:
        libp2p_protocols_bytes.inc(bytes.int64, labelValues = [s.protocol, "in"])

    trace "readOnce", s, bytes
    if bytes == 0:
      await s.closeUnderlying()
    return bytes
  except CancelledError as exc:
    await s.reset()
    raise exc
  except LPStreamError as exc:
    # Resetting is necessary because data has been lost in s.readBuf and
    # there's no way to gracefully recover / use the channel any more
    await s.reset()
    raise newLPStreamConnDownError(exc)

proc prepareWrite(
    s: LPChannel, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  # prepareWrite is the slow path of writing a message - see conditions in
  # write
  if s.remoteReset:
    raise newLPStreamResetError()
  if s.closedLocal:
    raise newLPStreamClosedError()
  if s.conn.closed:
    raise newLPStreamConnDownError()

  if msg.len == 0:
    return

  if s.writes >= MaxWrites:
    debug "Closing connection, too many in-flight writes on channel",
      s, conn = s.conn, writes = s.writes
    when defined(libp2p_mplex_metrics):
      libp2p_mplex_qlenclose.inc()
    await s.reset()
    await s.conn.close()
    return

  if not s.isOpen:
    await s.open()

  await s.conn.writeMsg(s.id, s.msgCode, msg)

proc completeWrite(
    s: LPChannel,
    fut: Future[void].Raising([CancelledError, LPStreamError]),
    msgLen: int,
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  try:
    s.writes += 1

    when defined(libp2p_mplex_metrics):
      libp2p_mplex_qlen.observe(s.writes.int64 - 1)
      libp2p_mplex_qtime.time:
        await fut
    else:
      await fut

    when defined(libp2p_network_protocols_metrics):
      if s.protocol.len > 0:
        # This crashes on Nim 2.0.2 with `--mm:orc` during `nimble test`
        # https://github.com/status-im/nim-metrics/issues/79
        libp2p_protocols_bytes.inc(msgLen.int64, labelValues = [s.protocol, "out"])

    s.activity = true
  except CancelledError as exc:
    # Chronos may still send the data
    raise exc
  except LPStreamConnDownError as exc:
    await s.reset()
    await s.conn.close()
    raise exc
  except LPStreamEOFError as exc:
    raise exc
  except LPStreamError as exc:
    trace "exception in lpchannel write handler", s, description = exc.msg
    await s.reset()
    await s.conn.close()
    raise newLPStreamConnDownError(exc)
  finally:
    s.writes -= 1

method write*(
    s: LPChannel, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  ## Write to mplex channel - there may be up to MaxWrite concurrent writes
  ## pending after which the peer is disconnected

  let closed = s.closedLocal or s.conn.closed

  let fut =
    if (not closed) and msg.len > 0 and s.writes < MaxWrites and s.isOpen:
      # Fast path: Avoid a copy of msg being kept in the closure created by
      # `{.async.}` as this drives up memory usage - the conditions are laid out
      # in prepareWrite
      s.conn.writeMsg(s.id, s.msgCode, msg)
    else:
      prepareWrite(s, msg)

  s.completeWrite(fut, msg.len)

method getWrapped*(s: LPChannel): Connection =
  s.conn

proc init*(
    L: type LPChannel,
    id: uint64,
    conn: Connection,
    initiator: bool,
    name: string = "",
    timeout: Duration = DefaultChanTimeout,
): LPChannel =
  let chann = L(
    id: id,
    name: name,
    conn: conn,
    initiator: initiator,
    timeout: timeout,
    isOpen: if initiator: false else: true,
    msgCode: if initiator: MessageType.MsgOut else: MessageType.MsgIn,
    closeCode: if initiator: MessageType.CloseOut else: MessageType.CloseIn,
    resetCode: if initiator: MessageType.ResetOut else: MessageType.ResetIn,
    dir: if initiator: Direction.Out else: Direction.In,
  )

  chann.initStream()

  when chronicles.enabledLogLevel == LogLevel.TRACE:
    chann.name =
      if chann.name.len > 0:
        chann.name
      else:
        $chann.oid

  trace "Created new lpchannel", s = chann, id, initiator

  return chann

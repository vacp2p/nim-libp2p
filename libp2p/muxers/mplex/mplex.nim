# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import tables, sequtils, oids
import chronos, chronicles, stew/byteutils, metrics
import
  ../muxer,
  ../../stream/connection,
  ../../stream/bufferstream,
  ../../utility,
  ../../peerinfo,
  ./coder,
  ./lpchannel

export muxer

logScope:
  topics = "libp2p mplex"

const MplexCodec* = "/mplex/6.7.0"

const MaxChannelCount = 200

when defined(libp2p_expensive_metrics):
  declareGauge(libp2p_mplex_channels, "mplex channels", labels = ["initiator", "peer"])

type
  InvalidChannelIdError* = object of MuxerError

  Mplex* = ref object of Muxer
    channels: array[bool, Table[uint64, LPChannel]]
    currentId: uint64
    inChannTimeout: Duration
    outChannTimeout: Duration
    isClosed: bool
    oid*: Oid
    maxChannCount: int

func shortLog*(m: Mplex): auto =
  shortLog(m.connection)

chronicles.formatIt(Mplex):
  shortLog(it)

proc newTooManyChannels(): ref TooManyChannels =
  newException(TooManyChannels, "max allowed channel count exceeded")

proc newInvalidChannelIdError(): ref InvalidChannelIdError =
  newException(InvalidChannelIdError, "max allowed channel count exceeded")

proc cleanupChann(m: Mplex, chann: LPChannel) {.async: (raises: []), inline.} =
  ## remove the local channel from the internal tables
  ##
  try:
    await chann.join()
    m.channels[chann.initiator].del(chann.id)
    trace "cleaned up channel", m, chann

    when defined(libp2p_expensive_metrics):
      libp2p_mplex_channels.set(
        m.channels[chann.initiator].len.int64,
        labelValues = [$chann.initiator, $m.connection.peerId],
      )
  except CancelledError as exc:
    warn "Error cleaning up mplex channel", m, chann, description = exc.msg

proc newStreamInternal*(
    m: Mplex,
    initiator: bool = true,
    chanId: uint64 = 0,
    name: string = "",
    timeout: Duration,
): LPChannel {.gcsafe, raises: [InvalidChannelIdError].} =
  ## create new channel/stream
  ##
  let id =
    if initiator:
      m.currentId.inc()
      m.currentId
    else:
      chanId

  if id in m.channels[initiator]:
    raise newInvalidChannelIdError()

  result = LPChannel.init(id, m.connection, initiator, name, timeout = timeout)

  result.peerId = m.connection.peerId
  result.observedAddr = m.connection.observedAddr
  result.transportDir = m.connection.transportDir
  when defined(libp2p_agents_metrics):
    result.shortAgent = m.connection.shortAgent

  trace "Creating new channel", m, channel = result, id, initiator, name

  m.channels[initiator][id] = result

  # All the errors are handled inside `cleanupChann()` procedure.
  asyncSpawn m.cleanupChann(result)

  when defined(libp2p_expensive_metrics):
    libp2p_mplex_channels.set(
      m.channels[initiator].len.int64, labelValues = [$initiator, $m.connection.peerId]
    )

proc handleStream(m: Mplex, chann: LPChannel) {.async: (raises: []).} =
  ## call the muxer stream handler for this channel
  ##
  await m.streamHandler(chann)
  trace "finished handling stream", m, chann
  doAssert(chann.closed, "connection not closed by handler!")

method handle*(m: Mplex) {.async: (raises: []).} =
  trace "Starting mplex handler", m
  try:
    while not m.connection.atEof:
      trace "waiting for data", m
      let
        (id, msgType, data) = await m.connection.readMsg()
        initiator = bool(ord(msgType) and 1)

      logScope:
        id = id
        initiator = initiator
        msgType = msgType
        size = data.len

      trace "read message from connection", m, data = data.shortLog

      var channel =
        if MessageType(msgType) != MessageType.New:
          let tmp = m.channels[initiator].getOrDefault(id, nil)
          if tmp == nil:
            trace "Channel not found, skipping", m
            continue

          tmp
        else:
          if m.channels[false].len > m.maxChannCount - 1:
            warn "too many channels created by remote peer",
              allowedMax = MaxChannelCount, m
            raise newTooManyChannels()

          let name = string.fromBytes(data)
          m.newStreamInternal(false, id, name, timeout = m.outChannTimeout)

      trace "Processing channel message", m, channel, data = data.shortLog

      case msgType
      of MessageType.New:
        trace "created channel", m, channel

        if m.streamHandler != nil:
          # Launch handler task
          # All the errors are handled inside `handleStream()` procedure.
          asyncSpawn m.handleStream(channel)
      of MessageType.MsgIn, MessageType.MsgOut:
        if data.len > MaxMsgSize:
          warn "attempting to send a packet larger than allowed",
            allowed = MaxMsgSize, channel
          raise newLPStreamLimitError()

        trace "pushing data to channel", m, channel, len = data.len
        try:
          await channel.pushData(data)
          trace "pushed data to channel", m, channel, len = data.len
        except LPStreamClosedError as exc:
          # Channel is being closed, but `cleanupChann` was not yet triggered.
          trace "pushing data to channel failed",
            m, channel, len = data.len, description = exc.msg
          discard # Ignore message, same as if `cleanupChann` had completed.
      of MessageType.CloseIn, MessageType.CloseOut:
        await channel.pushEof()
      of MessageType.ResetIn, MessageType.ResetOut:
        channel.remoteReset = true
        await channel.reset()
  except CancelledError:
    debug "Unexpected cancellation in mplex handler", m
  except LPStreamEOFError as exc:
    trace "Stream EOF", m, description = exc.msg
  except LPStreamError as exc:
    debug "Unexpected stream exception in mplex read loop", m, description = exc.msg
  except MuxerError as exc:
    debug "Unexpected muxer exception in mplex read loop", m, description = exc.msg
  finally:
    await m.close()
  trace "Stopped mplex handler", m

proc new*(
    M: type Mplex,
    conn: Connection,
    inTimeout: Duration = DefaultChanTimeout,
    outTimeout: Duration = DefaultChanTimeout,
    maxChannCount: int = MaxChannelCount,
): Mplex =
  M(
    connection: conn,
    inChannTimeout: inTimeout,
    outChannTimeout: outTimeout,
    oid: genOid(),
    maxChannCount: maxChannCount,
  )

method newStream*(
    m: Mplex, name: string = "", lazy: bool = false
): Future[Connection] {.async: (raises: [CancelledError, LPStreamError, MuxerError]).} =
  let channel = m.newStreamInternal(timeout = m.inChannTimeout)

  if not lazy:
    await channel.open()

  return Connection(channel)

method close*(m: Mplex) {.async: (raises: []).} =
  if m.isClosed:
    trace "Already closed", m
    return
  m.isClosed = true

  trace "Closing mplex", m

  var channs = toSeq(m.channels[false].values) & toSeq(m.channels[true].values)

  for chann in channs:
    await chann.close()

  await m.connection.close()

  # TODO while we're resetting, new channels may be created that will not be
  #      closed properly

  channs = toSeq(m.channels[false].values) & toSeq(m.channels[true].values)

  for chann in channs:
    await chann.reset()

  m.channels[false].clear()
  m.channels[true].clear()

  trace "Closed mplex", m

method getStreams*(m: Mplex): seq[Connection] {.gcsafe.} =
  for c in m.channels[false].values:
    result.add(c)
  for c in m.channels[true].values:
    result.add(c)

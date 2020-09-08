## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils, oids
import chronos, chronicles, stew/byteutils, metrics
import ../muxer,
       ../../stream/connection,
       ../../stream/bufferstream,
       ../../utility,
       ../../peerinfo,
       coder,
       types,
       lpchannel

export muxer

logScope:
  topics = "mplex"

const
  MaxChannelCount = 200

when defined(libp2p_expensive_metrics):
  declareGauge(libp2p_mplex_channels,
    "mplex channels", labels = ["initiator", "peer"])

type
  TooManyChannels* = object of CatchableError
  InvalidChannelIdError* = object of CatchableError

  Mplex* = ref object of Muxer
    channels: array[bool, Table[uint64, LPChannel]]
    currentId: uint64
    inChannTimeout: Duration
    outChannTimeout: Duration
    isClosed: bool
    oid*: Oid
    maxChannCount: int

func shortLog*(m: MPlex): auto = shortLog(m.connection)
chronicles.formatIt(Mplex): shortLog(it)

proc newTooManyChannels(): ref TooManyChannels =
  newException(TooManyChannels, "max allowed channel count exceeded")

proc newInvalidChannelIdError(): ref InvalidChannelIdError =
  newException(InvalidChannelIdError, "max allowed channel count exceeded")

proc cleanupChann(m: Mplex, chann: LPChannel) {.async, inline.} =
  ## remove the local channel from the internal tables
  ##
  try:
    await chann.join()
    m.channels[chann.initiator].del(chann.id)
    debug "cleaned up channel", m, chann

    when defined(libp2p_expensive_metrics):
      libp2p_mplex_channels.set(
        m.channels[chann.initiator].len.int64,
        labelValues = [$chann.initiator, $m.connection.peerInfo.peerId])
  except CancelledError:
    # This is top-level procedure which will work as separate task, so it
    # do not need to propogate CancelledError.
    debug "Unexpected cancellation in mplex channel cleanup",
      m, chann
  except CatchableError as exc:
    debug "error cleaning up mplex channel", exc = exc.msg, m, chann

proc newStreamInternal*(m: Mplex,
                        initiator: bool = true,
                        chanId: uint64 = 0,
                        name: string = "",
                        lazy: bool = false,
                        timeout: Duration):
                        LPChannel {.gcsafe.} =
  ## create new channel/stream
  ##
  let id = if initiator:
    m.currentId.inc(); m.currentId
    else: chanId

  if id in m.channels[initiator]:
    raise newInvalidChannelIdError()

  result = LPChannel.init(
    id,
    m.connection,
    initiator,
    name,
    lazy = lazy,
    timeout = timeout)

  result.peerInfo = m.connection.peerInfo
  result.observedAddr = m.connection.observedAddr

  trace "Creating new channel", id, initiator, name, m, channel = result

  m.channels[initiator][id] = result

  # All the errors are handled inside `cleanupChann()` procedure.
  asyncSpawn m.cleanupChann(result)

  when defined(libp2p_expensive_metrics):
    libp2p_mplex_channels.set(
      m.channels[initiator].len.int64,
      labelValues = [$initiator, $m.connection.peerInfo.peerId])

proc handleStream(m: Mplex, chann: LPChannel) {.async.} =
  ## call the muxer stream handler for this channel
  ##
  try:
    await m.streamHandler(chann)
    trace "finished handling stream", m, chann
    doAssert(chann.closed, "connection not closed by handler!")
  except CancelledError:
    trace "Unexpected cancellation in stream handler", m, chann
    await chann.reset()
    # This is top-level procedure which will work as separate task, so it
    # do not need to propogate CancelledError.
  except CatchableError as exc:
    trace "Exception in mplex stream handler",
      exc = exc.msg, m, chann
    await chann.reset()

method handle*(m: Mplex) {.async, gcsafe.} =
  trace "Starting mplex main loop", m
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

      case msgType:
        of MessageType.New:
          trace "created channel", m, channel

          if not isNil(m.streamHandler):
            # Launch handler task
            # All the errors are handled inside `handleStream()` procedure.
            asyncSpawn m.handleStream(channel)

        of MessageType.MsgIn, MessageType.MsgOut:
          if data.len > MaxMsgSize:
            warn "attempting to send a packet larger than allowed",
                 allowed = MaxMsgSize, channel
            raise newLPStreamLimitError()

          trace "pushing data to channel", m, channel
          await channel.pushTo(data)
          trace "pushed data to channel", m, channel

        of MessageType.CloseIn, MessageType.CloseOut:
          await channel.closeRemote()
        of MessageType.ResetIn, MessageType.ResetOut:
          await channel.reset()
  except CancelledError:
    # This procedure is spawned as task and it is not part of public API, so
    # there no way for this procedure to be cancelled implicitely.
    debug "Unexpected cancellation in mplex handler", m
  except CatchableError as exc:
    trace "Exception occurred", exception = exc.msg, m
  finally:
    trace "stopping mplex main loop", m
    await m.close()

proc init*(M: type Mplex,
           conn: Connection,
           inTimeout, outTimeout: Duration = DefaultChanTimeout,
           maxChannCount: int = MaxChannelCount): Mplex =
  M(connection: conn,
    inChannTimeout: inTimeout,
    outChannTimeout: outTimeout,
    oid: genOid(),
    maxChannCount: maxChannCount)

method newStream*(m: Mplex,
                  name: string = "",
                  lazy: bool = false): Future[Connection] {.async, gcsafe.} =
  let channel = m.newStreamInternal(
    lazy = lazy, timeout = m.inChannTimeout)

  if not lazy:
    await channel.open()

  return Connection(channel)

method close*(m: Mplex) {.async, gcsafe.} =
  if m.isClosed:
    return

  trace "closing mplex muxer", m

  m.isClosed = true

  let channs = toSeq(m.channels[false].values) & toSeq(m.channels[true].values)

  for chann in channs:
    await chann.reset()

  await m.connection.close()

  # TODO while we're resetting, new channels may be created that will not be
  #      closed properly
  m.channels[false].clear()
  m.channels[true].clear()

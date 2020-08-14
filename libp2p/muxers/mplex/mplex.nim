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

  Mplex* = ref object of Muxer
    channels: array[bool, Table[uint64, LPChannel]]
    currentId: uint64
    inChannTimeout: Duration
    outChannTimeout: Duration
    isClosed: bool
    oid*: Oid
    maxChannCount: int

proc newTooManyChannels(): ref TooManyChannels =
  newException(TooManyChannels, "max allowed channel count exceeded")

proc cleanupChann(m: Mplex, chann: LPChannel) {.async, inline.} =
  ## remove the local channel from the internal tables
  ##
  await chann.join()
  m.channels[chann.initiator].del(chann.id)
  trace "cleaned up channel", id = chann.id, oid = $chann.oid

  when defined(libp2p_expensive_metrics):
    libp2p_mplex_channels.set(
      m.channels[chann.initiator].len.int64,
      labelValues = [$chann.initiator, $m.connection.peerInfo])

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

  trace "creating new channel", channelId = id,
                                initiator = initiator,
                                name = name,
                                oid = $m.oid
  result = LPChannel.init(
    id,
    m.connection,
    initiator,
    name,
    lazy = lazy,
    timeout = timeout)

  result.peerInfo = m.connection.peerInfo
  result.observedAddr = m.connection.observedAddr

  doAssert(id notin m.channels[initiator],
    "channel slot already taken!")

  m.channels[initiator][id] = result

  asyncCheck m.cleanupChann(result)

  when defined(libp2p_expensive_metrics):
    libp2p_mplex_channels.set(
      m.channels[initiator].len.int64,
      labelValues = [$initiator, $m.connection.peerInfo])

proc handleStream(m: Mplex, chann: LPChannel) {.async.} =
  ## call the muxer stream handler for this channel
  ##
  try:
    await m.streamHandler(chann)
    trace "finished handling stream"
    doAssert(chann.closed, "connection not closed by handler!")
  except CancelledError as exc:
    trace "cancelling stream handler", exc = exc.msg
    await chann.reset()
    raise exc
  except CatchableError as exc:
    trace "exception in stream handler", exc = exc.msg
    await chann.reset()

method handle*(m: Mplex) {.async, gcsafe.} =
  logScope: moid = $m.oid

  trace "starting mplex main loop"
  try:
    defer:
      trace "stopping mplex main loop"
      await m.close()

    while true:
      trace "waiting for data"
      let
        (id, msgType, data) = await m.connection.readMsg()
        initiator = bool(ord(msgType) and 1)

      logScope:
        id = id
        initiator = initiator
        msgType = msgType
        size = data.len

      trace "read message from connection", data = data.shortLog

      var channel =
        if MessageType(msgType) != MessageType.New:
          let tmp = m.channels[initiator].getOrDefault(id, nil)
          if tmp == nil:
            trace "Channel not found, skipping"
            continue

          tmp
        else:
          if m.channels[false].len > m.maxChannCount - 1:
            warn "too many channels created by remote peer", allowedMax = MaxChannelCount
            raise newTooManyChannels()

          let name = string.fromBytes(data)
          m.newStreamInternal(false, id, name, timeout = m.outChannTimeout)

      logScope:
        name = channel.name
        oid = $channel.oid

      case msgType:
        of MessageType.New:
          trace "created channel"

          if not isNil(m.streamHandler):
            # launch handler task
            asyncCheck m.handleStream(channel)

        of MessageType.MsgIn, MessageType.MsgOut:
          if data.len > MaxMsgSize:
            warn "attempting to send a packet larger than allowed", allowed = MaxMsgSize
            raise newLPStreamLimitError()

          trace "pushing data to channel"
          await channel.pushTo(data)
          trace "pushed data to channel"

        of MessageType.CloseIn, MessageType.CloseOut:
          trace "closing channel"
          await channel.closeRemote()
          trace "closed channel"
        of MessageType.ResetIn, MessageType.ResetOut:
          trace "resetting channel"
          await channel.reset()
          trace "reset channel"
  except CancelledError as exc:
    raise exc
  except LPStreamEOFError as exc:
    trace "stream closed", msg = exc.msg
  except CatchableError as exc:
    warn "Exception occurred", exception = exc.msg

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

  trace "closing mplex muxer", moid = $m.oid

  m.isClosed = true

  let channs = toSeq(m.channels[false].values) & toSeq(m.channels[true].values)

  for chann in channs:
    await chann.reset()

  await m.connection.close()

  # TODO while we're resetting, new channels may be created that will not be
  #      closed properly
  m.channels[false].clear()
  m.channels[true].clear()

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

declareGauge(libp2p_mplex_channels, "mplex channels", labels = ["initiator", "peer"])

type
  Mplex* = ref object of Muxer
    remote: Table[uint64, LPChannel]
    local: Table[uint64, LPChannel]
    currentId*: uint64
    maxChannels*: uint64
    inChannTimeout: Duration
    outChannTimeout: Duration
    isClosed: bool
    oid*: Oid

proc getChannelList(m: Mplex, initiator: bool): var Table[uint64, LPChannel] =
  if initiator:
    trace "picking local channels", initiator = initiator, oid = $m.oid
    result = m.local
  else:
    trace "picking remote channels", initiator = initiator, oid = $m.oid
    result = m.remote

proc newStreamInternal*(m: Mplex,
                        initiator: bool = true,
                        chanId: uint64 = 0,
                        name: string = "",
                        lazy: bool = false,
                        timeout: Duration):
                        Future[LPChannel] {.async, gcsafe.} =
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

  doAssert(id notin m.getChannelList(initiator),
    "channel slot already taken!")

  m.getChannelList(initiator)[id] = result
  libp2p_mplex_channels.set(
    m.getChannelList(initiator).len.int64,
    labelValues = [$initiator,
                   $m.connection.peerInfo])

proc cleanupChann(m: Mplex, chann: LPChannel) {.async, inline.} =
  ## remove the local channel from the internal tables
  ##
  await chann.closeEvent.wait()
  if not isNil(chann):
    m.getChannelList(chann.initiator).del(chann.id)
    trace "cleaned up channel", id = chann.id

  libp2p_mplex_channels.set(
    m.getChannelList(chann.initiator).len.int64,
    labelValues = [$chann.initiator,
                    $m.connection.peerInfo])

proc handleStream(m: Mplex, chann: LPChannel) {.async.} =
  ## call the muxer stream handler for this channel
  ##
  try:
    await m.streamHandler(chann)
    trace "finished handling stream"
    doAssert(chann.closed, "connection not closed by handler!")
  except CancelledError as exc:
    trace "cancling stream handler", exc = exc.msg
    await chann.reset()
    raise
  except CatchableError as exc:
    trace "exception in stream handler", exc = exc.msg
    await chann.reset()
    await m.cleanupChann(chann)

method handle*(m: Mplex) {.async, gcsafe.} =
  trace "starting mplex main loop", oid = $m.oid
  try:
    defer:
      trace "stopping mplex main loop", oid = $m.oid
      await m.close()

    while not m.connection.atEof:
      trace "waiting for data", oid = $m.oid
      let (id, msgType, data) = await m.connection.readMsg()
      trace "read message from connection", id = id,
                                            msgType = msgType,
                                            data = data.shortLog,
                                            oid = $m.oid

      let initiator = bool(ord(msgType) and 1)
      var channel: LPChannel
      if MessageType(msgType) != MessageType.New:
        let channels = m.getChannelList(initiator)
        if id notin channels:

          trace "Channel not found, skipping", id = id,
                                                initiator = initiator,
                                                msg = msgType,
                                                oid = $m.oid
          continue
        channel = channels[id]

      logScope:
        id = id
        initiator = initiator
        msgType = msgType
        size = data.len
        muxer_oid = $m.oid

      case msgType:
        of MessageType.New:
          let name = string.fromBytes(data)
          channel = await m.newStreamInternal(
            false,
            id,
            name,
            timeout = m.outChannTimeout)

          trace "created channel", name = channel.name,
                                    oid = $channel.oid

          if not isNil(m.streamHandler):
            # launch handler task
            asyncCheck m.handleStream(channel)

        of MessageType.MsgIn, MessageType.MsgOut:
          logScope:
            name = channel.name
            oid = $channel.oid

          trace "pushing data to channel"

          if data.len > MaxMsgSize:
            warn "attempting to send a packet larger than allowed", allowed = MaxMsgSize,
                                                                    sending = data.len
            raise newLPStreamLimitError()

          await channel.pushTo(data)

        of MessageType.CloseIn, MessageType.CloseOut:
          logScope:
            name = channel.name
            oid = $channel.oid

          trace "closing channel"

          await channel.closeRemote()
          await m.cleanupChann(channel)

          trace "deleted channel"
        of MessageType.ResetIn, MessageType.ResetOut:
          logScope:
            name = channel.name
            oid = $channel.oid

          trace "resetting channel"

          await channel.reset()
          await m.cleanupChann(channel)

          trace "deleted channel"
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "Exception occurred", exception = exc.msg, oid = $m.oid

proc init*(M: type Mplex,
           conn: Connection,
           maxChanns: uint = MaxChannels,
           inTimeout, outTimeout: Duration = DefaultChanTimeout): Mplex =
  M(connection: conn,
    maxChannels: maxChanns,
    inChannTimeout: inTimeout,
    outChannTimeout: outTimeout,
    remote: initTable[uint64, LPChannel](),
    local: initTable[uint64, LPChannel](),
    oid: genOid())

method newStream*(m: Mplex,
                  name: string = "",
                  lazy: bool = false): Future[Connection] {.async, gcsafe.} =
  let channel = await m.newStreamInternal(
    lazy = lazy, timeout = m.inChannTimeout)

  if not lazy:
    await channel.open()

  asyncCheck m.cleanupChann(channel)
  return Connection(channel)

method close*(m: Mplex) {.async, gcsafe.} =
  if m.isClosed:
    return

  defer:
    m.remote.clear()
    m.local.clear()
    m.isClosed = true

  trace "closing mplex muxer", oid = $m.oid
  let channs = toSeq(m.remote.values) &
    toSeq(m.local.values)

  for chann in channs:
    await chann.reset()
    await m.cleanupChann(chann)

  await m.connection.close()

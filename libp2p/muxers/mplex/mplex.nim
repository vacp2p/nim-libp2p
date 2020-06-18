## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils, oids
import chronos, chronicles, stew/byteutils
import ../muxer,
       ../../stream/connection,
       ../../stream/bufferstream,
       ../../utility,
       ../../errors,
       coder,
       types,
       lpchannel

logScope:
  topics = "mplex"

type
  Mplex* = ref object of Muxer
    remote: Table[uint64, LPChannel]
    local: Table[uint64, LPChannel]
    handlerFuts: seq[Future[void]]
    currentId*: uint64
    maxChannels*: uint64
    isClosed: bool
    when chronicles.enabledLogLevel == LogLevel.TRACE:
      oid*: Oid

proc getChannelList(m: Mplex, initiator: bool): var Table[uint64, LPChannel] =
  if initiator:
    trace "picking local channels", initiator = initiator, oid = m.oid
    result = m.local
  else:
    trace "picking remote channels", initiator = initiator, oid = m.oid
    result = m.remote

proc newStreamInternal*(m: Mplex,
                        initiator: bool = true,
                        chanId: uint64 = 0,
                        name: string = "",
                        lazy: bool = false):
                        Future[LPChannel] {.async, gcsafe.} =
  ## create new channel/stream
  let id = if initiator:
    m.currentId.inc(); m.currentId
    else: chanId

  trace "creating new channel", channelId = id,
                                initiator = initiator,
                                name = name,
                                oid = m.oid
  result = newChannel(id,
                      m.connection,
                      initiator,
                      name,
                      lazy = lazy)

  result.peerInfo = m.connection.peerInfo
  result.observedAddr = m.connection.observedAddr

  m.getChannelList(initiator)[id] = result

method handle*(m: Mplex) {.async, gcsafe.} =
  trace "starting mplex main loop", oid = m.oid
  try:
    try:
      while not m.connection.closed:
        trace "waiting for data", oid = m.oid
        let (id, msgType, data) = await m.connection.readMsg()
        trace "read message from connection", id = id,
                                              msgType = msgType,
                                              data = data.shortLog,
                                              oid = m.oid

        let initiator = bool(ord(msgType) and 1)
        var channel: LPChannel
        if MessageType(msgType) != MessageType.New:
          let channels = m.getChannelList(initiator)
          if id notin channels:

            trace "Channel not found, skipping", id = id,
                                                 initiator = initiator,
                                                 msg = msgType,
                                                 oid = m.oid
            continue
          channel = channels[id]

        logScope:
          id = id
          initiator = initiator
          msgType = msgType
          size = data.len
          oid = m.oid

        case msgType:
          of MessageType.New:
            let name = string.fromBytes(data)
            channel = await m.newStreamInternal(false, id, name)

            trace "created channel", name = channel.name,
                                     chann_iod = channel.oid

            if not isNil(m.streamHandler):
              var fut = newFuture[void]()
              proc handler() {.async.} =
                try:
                  await m.streamHandler(channel)
                  trace "finished handling stream"
                  # doAssert(channel.closed, "connection not closed by handler!")
                except CatchableError as exc:
                  trace "exception in stream handler", exc = exc.msg
                  await channel.reset()
                finally:
                  m.handlerFuts.keepItIf(it != fut)

              fut = handler()

          of MessageType.MsgIn, MessageType.MsgOut:
            logScope:
              name = channel.name
              chann_iod = channel.oid

            trace "pushing data to channel"

            if data.len > MaxMsgSize:
              raise newLPStreamLimitError()
            await channel.pushTo(data)
          of MessageType.CloseIn, MessageType.CloseOut:
            logScope:
              name = channel.name
              chann_iod = channel.oid

            trace "closing channel"

            await channel.closeRemote()
            m.getChannelList(initiator).del(id)
            trace "deleted channel"
          of MessageType.ResetIn, MessageType.ResetOut:
            logScope:
              name = channel.name
              chann_iod = channel.oid

            trace "resetting channel"

            await channel.reset()
            m.getChannelList(initiator).del(id)
            trace "deleted channel"
    finally:
      trace "stopping mplex main loop", oid = m.oid
      await m.close()
  except CatchableError as exc:
    trace "Exception occurred", exception = exc.msg, oid = m.oid

proc newMplex*(conn: Connection,
               maxChanns: uint = MaxChannels): Mplex =
  new result
  result.connection = conn
  result.maxChannels = maxChanns
  result.remote = initTable[uint64, LPChannel]()
  result.local = initTable[uint64, LPChannel]()

  when chronicles.enabledLogLevel == LogLevel.TRACE:
    result.oid = genOid()

proc cleanupChann(m: Mplex, chann: LPChannel) {.async, inline.} =
  ## remove the local channel from the internal tables
  ##
  await chann.closeEvent.wait()
  if not isNil(chann):
    m.getChannelList(true).del(chann.id)
    trace "cleaned up channel", id = chann.id

method newStream*(m: Mplex,
                  name: string = "",
                  lazy: bool = false): Future[Connection] {.async, gcsafe.} =
  let channel = await m.newStreamInternal(lazy = lazy)
  if not lazy:
    await channel.open()

  asyncCheck m.cleanupChann(channel)
  return Connection(channel)

method close*(m: Mplex) {.async, gcsafe.} =
  if m.isClosed:
    return

  try:
    trace "closing mplex muxer", oid = m.oid
    let channs = toSeq(m.remote.values) &
      toSeq(m.local.values)

    for chann in channs:
      try:
        await chann.reset()
      except CatchableError as exc:
        warn "error resetting channel", exc = exc.msg

    checkFutures(
      await allFinished(m.handlerFuts))

    await m.connection.close()
  finally:
    m.remote.clear()
    m.local.clear()
    m.handlerFuts = @[]
    m.isClosed = true

## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils, oids
import chronos, chronicles
import ../muxer,
       ../../connection,
       ../../stream/lpstream,
       ../../stream/bufferstream,
       ../../utility,
       ../../errors,
       coder,
       types,
       lpchannel

logScope:
  topic = "Mplex"

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
  let id = if initiator: m.currentId.inc(); m.currentId else: chanId
  trace "creating new channel", channelId = id,
                                initiator = initiator,
                                name = name,
                                oid = m.oid
  result = newChannel(id,
                      m.connection,
                      initiator,
                      name,
                      lazy = lazy)
  m.getChannelList(initiator)[id] = result

method handle*(m: Mplex) {.async, gcsafe.} =
  trace "starting mplex main loop", oid = m.oid
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

      case msgType:
        of MessageType.New:
          let name = cast[string](data)
          channel = await m.newStreamInternal(false, id, name)
          trace "created channel", id = id,
                                   name = name,
                                   inititator = channel.initiator,
                                   channoid = channel.oid,
                                   oid = m.oid
          if not isNil(m.streamHandler):
            let stream = newConnection(channel)
            stream.peerInfo = m.connection.peerInfo

            var fut = newFuture[void]()
            proc handler() {.async.} =
              tryAndWarn "mplex channel handler":
                await m.streamHandler(stream)

            fut = handler()
            m.handlerFuts.add(fut)
            fut.addCallback do(udata: pointer):
                m.handlerFuts.keepItIf(it != fut)

        of MessageType.MsgIn, MessageType.MsgOut:
          trace "pushing data to channel", id = id,
                                           initiator = initiator,
                                           msgType = msgType,
                                           size = data.len,
                                           name = channel.name,
                                           channoid = channel.oid,
                                           oid = m.oid

          if data.len > MaxMsgSize:
            raise newLPStreamLimitError()
          await channel.pushTo(data)
        of MessageType.CloseIn, MessageType.CloseOut:
          trace "closing channel", id = id,
                                   initiator = initiator,
                                   msgType = msgType,
                                   name = channel.name,
                                   channoid = channel.oid,
                                   oid = m.oid

          await channel.closeRemote()
          m.getChannelList(initiator).del(id)
          trace "deleted channel", id = id,
                                   initiator = initiator,
                                   msgType = msgType,
                                   name = channel.name,
                                   channoid = channel.oid,
                                   oid = m.oid
        of MessageType.ResetIn, MessageType.ResetOut:
          trace "resetting channel", id = id,
                                     initiator = initiator,
                                     msgType = msgType,
                                     name = channel.name,
                                     channoid = channel.oid,
                                     oid = m.oid

          await channel.reset()
          m.getChannelList(initiator).del(id)
          trace "deleted channel", id = id,
                                   initiator = initiator,
                                   msgType = msgType,
                                   name = channel.name,
                                   channoid = channel.oid,
                                   oid = m.oid
          break
  except CatchableError as exc:
    trace "Exception occurred", exception = exc.msg, oid = m.oid
  finally:
    trace "stopping mplex main loop", oid = m.oid
    await m.close()

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
  result = newConnection(channel)
  result.peerInfo = m.connection.peerInfo

  asyncCheck m.cleanupChann(channel)

method close*(m: Mplex) {.async, gcsafe.} =
  if m.isClosed:
    return

  trace "closing mplex muxer", oid = m.oid

  # let the other end know that we're closing
  checkFutures(
    await allFinished(
      toSeq(m.remote.values).mapIt(it.close()) &
        toSeq(m.local.values).mapIt(it.close())))

  # send a reset as well, this will release
  # local resources deterministically
  # TODO: shouldn't be needed once close has a
  # timeout to track the close flow, if the timeout
  # expires, it will automatically send a reset,
  # this wouldn't probably be needed. Re-evaluate
  # as soon as timer is in place.
  checkFutures(
    await allFinished(
      toSeq(m.remote.values).mapIt(it.reset()) &
        toSeq(m.local.values).mapIt(it.reset())))

  checkFutures(await allFinished(m.handlerFuts))

  await m.connection.close()
  m.remote.clear()
  m.local.clear()
  m.handlerFuts = @[]
  m.isClosed = true

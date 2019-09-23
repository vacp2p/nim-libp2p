## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

## TODO: I have to be carefull to clean channels up correctly,
## both by removing from the internal tables as well as
## releasing resource when the channel is completelly 
## finished. This is complicated because half-closed 
## streams makes closing channels non-deterministic. 
## 
## This still needs to be implemented properly - I'm leaving it 
## here to not forget that this needs to be fixed ASAP.

import tables, sequtils, options, strformat
import chronos, chronicles
import coder, types, lpchannel,
       ../muxer,
       ../../varint, 
       ../../connection, 
       ../../vbuffer, 
       ../../protocols/protocol,
       ../../stream/bufferstream, 
       ../../stream/lpstream

logScope:
  topic = "Mplex"

type
  Mplex* = ref object of Muxer
    remote*: Table[uint, LPChannel]
    local*: Table[uint, LPChannel]
    currentId*: uint
    maxChannels*: uint

proc newMplexUnknownMsgError(): ref MplexUnknownMsgError =
  result = newException(MplexUnknownMsgError, "Unknown mplex message type")

proc getChannelList(m: Mplex, initiator: bool): var Table[uint, LPChannel] =
  if initiator:
    result = m.remote
  else:
    result = m.local

proc newStreamInternal*(m: Mplex,
                        initiator: bool = true,
                        chanId: uint = 0,
                        name: string = ""):
                        Future[LPChannel] {.async, gcsafe.} = 
  ## create new channel/stream
  let id = if initiator: m.currentId.inc(); m.currentId else: chanId
  result = newChannel(id, m.connection, initiator, name)
  m.getChannelList(initiator)[id] = result

method handle*(m: Mplex) {.async, gcsafe.} = 
  trace "starting mplex main loop"
  try:
    while not m.connection.closed:
      let msgRes = await m.connection.readMsg()
      if msgRes.isNone:
        continue

      let (id, msgType, data) = msgRes.get()
      let initiator = bool(ord(msgType) and 1)
      var channel: LPChannel
      if MessageType(msgType) != MessageType.New:
        let channels = m.getChannelList(initiator)
        if not channels.contains(id):
          trace "handle: Channel with id and msg type ", id = id, msg = msgType
          continue
        channel = channels[id]

      case msgType:
        of MessageType.New:
          let name = cast[string](data)
          channel = await m.newStreamInternal(false, id, name)
          trace "handle: created channel ", id = id, name = name
          if not isNil(m.streamHandler):
            let stream = newConnection(channel)
            stream.peerInfo = m.connection.peerInfo
            let handlerFut = m.streamHandler(stream)

            # channel cleanup routine
            proc cleanUpChan(udata: pointer) {.gcsafe.} = 
              if handlerFut.finished:
                channel.close().addCallback(
                  proc(udata: pointer) = 
                    channel.cleanUp()
                    .addCallback(proc(udata: pointer) = 
                      trace "handle: cleaned up channel ", id = id))
              handlerFut.addCallback(cleanUpChan)
            continue
        of MessageType.MsgIn, MessageType.MsgOut:
            trace "handle: pushing data to channel ", id = id, msgType = msgType
            await channel.pushTo(data)
        of MessageType.CloseIn, MessageType.CloseOut:
          trace "handle: closing channel ", id = id, msgType = msgType
          await channel.closedByRemote()
          m.getChannelList(initiator).del(id)
        of MessageType.ResetIn, MessageType.ResetOut:
          trace "handle: resetting channel ", id = id
          await channel.resetByRemote()
          break
        else: raise newMplexUnknownMsgError()
  except:
    error "exception occurred", exception = getCurrentExceptionMsg()
  finally:
    await m.connection.close()

proc newMplex*(conn: Connection, 
               maxChanns: uint = MaxChannels): Mplex =
  new result
  result.connection = conn
  result.maxChannels = maxChanns
  result.remote = initTable[uint, LPChannel]()
  result.local = initTable[uint, LPChannel]()

method newStream*(m: Mplex, name: string = ""): Future[Connection] {.async, gcsafe.} =
  let channel = await m.newStreamInternal()
  await m.connection.writeMsg(channel.id, MessageType.New, name)
  result = newConnection(channel)
  result.peerInfo = m.connection.peerInfo

method close*(m: Mplex) {.async, gcsafe.} = 
    await allFutures(@[allFutures(toSeq(m.remote.values).mapIt(it.close())),
                       allFutures(toSeq(m.local.values).mapIt(it.close()))])
    m.connection.reset()

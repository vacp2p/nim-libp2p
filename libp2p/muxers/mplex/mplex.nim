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

import tables, sequtils, strformat, options
import chronos
import coder, types, channel,
       ../../varint, 
       ../../connection, 
       ../../vbuffer, 
       ../../protocols/protocol,
       ../../stream/bufferstream, 
       ../../stream/lpstream, 
       ../muxer

type
  Mplex* = ref object of Muxer
    remote*: Table[uint, Channel]
    local*: Table[uint, Channel]
    currentId*: uint
    maxChannels*: uint

proc newMplexNoSuchChannel(id: uint, msgType: MessageType): ref MplexNoSuchChannel =
  result = newException(MplexNoSuchChannel, &"No such channel id {$id} and message {$msgType}")

proc newMplexUnknownMsgError(): ref MplexUnknownMsgError =
  result = newException(MplexUnknownMsgError, "Unknown mplex message type")

proc getChannelList(m: Mplex, initiator: bool): var Table[uint, Channel] =
  if initiator:
    result = m.remote
  else:
    result = m.local

proc newStreamInternal*(m: Mplex,
                        initiator: bool = true,
                        chanId: uint = 0,
                        name: string = ""):
                        Future[Channel] {.async, gcsafe.} = 
  ## create new channel/stream
  let id = if initiator: m.currentId.inc(); m.currentId else: chanId
  result = newChannel(id, m.connection, initiator, name)
  m.getChannelList(initiator)[id] = result

method handle*(m: Mplex): Future[void] {.async, gcsafe.} = 
    while not m.connection.closed:
      try:
        let (id, msgType, data) = await m.connection.readMsg()
        let initiator = bool(ord(msgType) and 1)
        var channel: Channel
        if MessageType(msgType) != MessageType.New:
          let channels = m.getChannelList(initiator)
          if not channels.contains(id):
            raise newMplexNoSuchChannel(id, msgType)
          channel = channels[id]

        case msgType:
          of MessageType.New:
            channel = await m.newStreamInternal(false, id, cast[string](data))
            if not isNil(m.streamHandler):
              await m.streamHandler(newConnection(channel))
          of MessageType.MsgIn, MessageType.MsgOut:
              await channel.pushTo(data)
          of MessageType.CloseIn, MessageType.CloseOut:
            await channel.closedByRemote()
            m.getChannelList(initiator).del(id)
          of MessageType.ResetIn, MessageType.ResetOut:
            await channel.resetByRemote()
          else: raise newMplexUnknownMsgError()
      finally:
        await m.connection.close()

proc newMplex*(conn: Connection, 
               maxChanns: uint = MaxChannels): Mplex =
  new result
  result.connection = conn
  result.maxChannels = maxChanns
  result.remote = initTable[uint, Channel]()
  result.local = initTable[uint, Channel]()

method newStream*(m: Mplex, name: string = ""): Future[Connection] {.async, gcsafe.} =
  let channel = await m.newStreamInternal()
  await m.connection.writeMsg(channel.id, MessageType.New, cast[seq[byte]](toSeq(name.items)))
  result = newConnection(channel)

method close*(m: Mplex) {.async, gcsafe.} = 
    await allFutures(@[allFutures(toSeq(m.remote.values).mapIt(it.close())),
                       allFutures(toSeq(m.local.values).mapIt(it.close()))])
    m.connection.reset()

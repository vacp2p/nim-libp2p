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
    remote*: Table[int, Channel]
    local*: Table[int, Channel]
    currentId*: int
    maxChannels*: uint

proc newMplexNoSuchChannel(id: int, msgType: MessageType): ref MplexNoSuchChannel =
  result = newException(MplexNoSuchChannel, &"No such channel id {$id} and message {$msgType}")

proc newMplexUnknownMsgError(): ref MplexUnknownMsgError =
  result = newException(MplexUnknownMsgError, "Unknown mplex message type")

proc getChannelList(m: Mplex, initiator: bool): var Table[int, Channel] =
  if initiator:
    result = m.remote
  else:
    result = m.local

proc newStreamInternal*(m: Mplex,
                        initiator: bool = true,
                        chanId: int,
                        name: string = ""):
                        Future[Channel] {.async, gcsafe.} = 
  ## create new channel/stream
  let id = if initiator: m.currentId.inc(); m.currentId else: chanId
  result = newChannel(id, m.connection, initiator, name)
  m.getChannelList(initiator)[id] = result

proc newStreamInternal*(m: Mplex): Future[Channel] {.gcsafe.} = 
  result = m.newStreamInternal(true, 0)

method handle*(m: Mplex): Future[void] {.async, gcsafe.} = 
  try:
    while not m.connection.closed:
      let (id, msgType) = await m.connection.readHeader()
      let initiator = bool(ord(msgType) and 1)
      var channel: Channel
      if MessageType(msgType) != MessageType.New:
        let channels = m.getChannelList(initiator)
        if not channels.contains(id.int):
          raise newMplexNoSuchChannel(id.int, msgType)
        channel = channels[id.int]

      case msgType:
        of MessageType.New:
          var name: seq[byte]
          try:
            name = await m.connection.readLp()
          except LPStreamIncompleteError as exc:
            echo exc.msg
          except Exception as exc:
            echo exc.msg
            raise

          let channel = await m.newStreamInternal(false, id.int, cast[string](name))
          if not isNil(m.streamHandler):
            channel.handlerFuture = m.streamHandler(newConnection(channel))
        of MessageType.MsgIn, MessageType.MsgOut:
          let msg = await m.connection.readLp()
          await channel.pushTo(msg)
        of MessageType.CloseIn, MessageType.CloseOut:
          await channel.closedByRemote()
          m.getChannelList(initiator).del(id.int)
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
  result.remote = initTable[int, Channel]()
  result.local = initTable[int, Channel]()

method newStream*(m: Mplex, name: string = ""): Future[Connection] {.async, gcsafe.} =
  let channel = await m.newStreamInternal()
  await m.connection.writeHeader(channel.id, MessageType.New, len(name))
  if name.len > 0:
    await m.connection.write(name)
  result = newConnection(channel)

method close*(m: Mplex) {.async, gcsafe.} = 
    await allFutures(@[allFutures(toSeq(m.remote.values).mapIt(it.close())),
                       allFutures(toSeq(m.local.values).mapIt(it.close()))])
    m.connection.reset()

## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils
import chronos
import ../../varint, ../../connection, 
       ../../vbuffer, ../../protocol,
       ../../stream/bufferstream, 
       ../../stream/lpstream, ../muxer,
       coder, types, channel

type
  Mplex* = ref object of Muxer
    remote*: Table[int, Channel]
    local*: Table[int, Channel]
    currentId*: int
    maxChannels*: uint
    streamHandler*: StreamHandler

proc newMplexUnknownMsgError(): ref MplexUnknownMsgError =
  result = newException(MplexUnknownMsgError, "Unknown mplex message type")

##########################################
##               Mplex
##########################################

proc getChannelList(m: Mplex, initiator: bool): var Table[int, Channel] =
  if initiator:
    result = m.remote
  else:
    result = m.local

proc newStreamInternal*(m: Mplex,
                        initiator: bool = true,
                        chanId: int):
                        Future[Channel] {.async, gcsafe.} = 
  ## create new channel/stream
  let id = if initiator: m.currentId.inc(); m.currentId else: chanId
  proc writeHandler(data: seq[byte]): Future[void] {.async, gcsafe.} = 
    let msgType = if initiator: MessageType.MsgOut else: MessageType.MsgIn
    await m.connection.writeHeader(id, msgType, data.len) # write header
    await m.connection.write(data) # write data

  result = newChannel(id, initiator, writeHandler)
  m.getChannelList(initiator)[id] = result

proc newStreamInternal*(m: Mplex): Future[Channel] {.gcsafe.} = 
  result = m.newStreamInternal(true, 0)

proc handle*(m: Mplex): Future[void] {.async, gcsafe.} = 
  try:
    while not m.connection.closed:
      let (id, msgType) = await m.connection.readHeader()
      let initiator = bool(ord(msgType) and 1)
      case msgType:
        of MessageType.New:
          let channel = await m.newStreamInternal(false, id.int)
          channel.handlerFuture = m.streamHandler(newConnection(channel))
        of MessageType.MsgIn, MessageType.MsgOut:
          let channel = m.getChannelList(initiator)[id.int]
          let msg = await m.connection.readLp()
          await channel.pushTo(msg)
        of MessageType.CloseIn, MessageType.CloseOut:
          let channel = m.getChannelList(initiator)[id.int]
          await channel.close()
        of MessageType.ResetIn, MessageType.ResetOut:
          let channel = m.getChannelList(initiator)[id.int]
          await channel.reset()
        else: raise newMplexUnknownMsgError()
  except Exception as exc:
    #TODO: add proper loging
    discard
  finally:
    await m.connection.close()

proc newMplex*(conn: Connection, 
               streamHandler: StreamHandler, 
               maxChanns: uint = MaxChannels): Mplex =
  new result
  result.connection = conn
  result.maxChannels = maxChanns
  result.streamHandler = streamHandler
  result.remote = initTable[int, Channel]()
  result.local = initTable[int, Channel]()

method newStream*(m: Mplex): Future[Connection] {.async, gcsafe.} =
  let channel = await m.newStreamInternal()
  await m.connection.writeHeader(channel.id, MessageType.New, 0)
  result = newConnection(channel)

method close*(m: Mplex) {.async, gcsafe.} = 
    await allFutures(@[allFutures(toSeq(m.remote.values).mapIt(it.close())),
                       allFutures(toSeq(m.local.values).mapIt(it.close()))])
    await m.connection.close()

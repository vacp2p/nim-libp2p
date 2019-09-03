## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import sequtils
import chronos
import ../varint, ../connection, 
       ../vbuffer, ../protocol,
       ../stream/bufferstream, 
       muxer

const MaxMsgSize* = 1 shl 20 # 1mb
const MaxChannels* = 1000
const MplexCodec* = "/mplex/6.7.0"

type 
  MplexUnknownMsgError* = object of CatchableError
  MessageType* {.pure.} = enum
    New,
    MsgIn,
    MsgOut,
    CloseIn,
    CloseOut,
    ResetIn,
    ResetOut

  StreamHandler = proc(conn: Connection): Future[void] {.gcsafe.}
  Mplex* = ref object of Muxer
    remote*: seq[Channel]
    local*: seq[Channel]
    currentId*: int
    maxChannels*: uint
    streamHandler*: StreamHandler

  Channel* = ref object of BufferStream
    id*: int
    initiator*: bool
    isReset*: bool
    closedLocal*: bool
    closedRemote*: bool
    mplex*: Mplex

proc newMplexUnknownMsgError*(): ref MplexUnknownMsgError =
  result = newException(MplexUnknownMsgError, "Unknown mplex message type")

##########################################
##           Read/Write Helpers
##########################################

proc readHeader*(conn: Connection): Future[(uint, MessageType)] {.async, gcsafe.} = 
  var
    header: uint
    length: int
    res: VarintStatus
  var buffer = newSeq[byte](10)
  try:
    for i in 0..<len(buffer):
      await conn.readExactly(addr buffer[i], 1)
      res = LP.getUVarint(buffer.toOpenArray(0, i), length, header)
      if res == VarintStatus.Success:
        return (header shr 3, MessageType(header and 0x7))
    if res != VarintStatus.Success:
      buffer.setLen(0)
      return
  except TransportIncompleteError:
    buffer.setLen(0)

proc writeHeader*(conn: Connection,
                  id: int,
                  msgType: MessageType, 
                  size: int) {.async, gcsafe.} =
  ## write lenght prefixed
  var buf = initVBuffer()
  buf.writeVarint(LPSomeUVarint(id.uint shl 3 or msgType.uint))
  buf.writeVarint(LPSomeUVarint(size.uint))
  buf.finish()
  result = conn.write(buf.buffer)

##########################################
##               Channel
##########################################

proc newChannel*(mplex: Mplex,
                 id: int,
                 initiator: bool,
                 handler: WriteHandler,
                 size: int = MaxMsgSize): Channel = 
  new result
  result.id = id
  result.mplex = mplex
  result.initiator = initiator
  result.writeHandler = handler
  result.maxSize = size

proc closed*(s: Channel): bool = s.closedLocal and s.closedRemote
proc close*(s: Channel) {.async.} = discard
proc reset*(s: Channel) {.async.} = discard

##########################################
##
##               Mplex
##
##########################################

proc getChannelList(m: Mplex, initiator: bool): var seq[Channel] =
  if initiator: 
    result = m.remote
  else:
    result = m.local

proc newStream*(m: Mplex,
                chanId: int = -1,
                initiator: bool = true):
                Future[Connection] {.async, gcsafe.} = 
  ## create new channel/stream
  defer: inc(m.currentId)
  let id = if chanId > -1: chanId else: m.currentId
  proc writeHandler(data: seq[byte]): Future[void] {.async, gcsafe.} = 
    let msgType = if initiator: MessageType.MsgIn else: MessageType.MsgOut
    await m.connection.writeHeader(id, msgType, data.len) # write header
    await m.connection.write(data) # write data

  let channel = newChannel(m, id, initiator, writeHandler)
  m.getChannelList(initiator)[id] = channel
  result = newConnection(channel)

proc handle*(m: Mplex) {.async, gcsafe.} = 
  while not m.connection.closed:
    let (id, msgType) = await m.connection.readHeader()
    let initiator = bool(ord(msgType) and 1)
    case msgType:
      of MessageType.New:
        await m.streamHandler(await m.newStream(id.int, false))
      of MessageType.MsgIn, MessageType.MsgOut:
        await m.getChannelList(initiator)[id.int].pushTo(await m.connection.readLp())
      of MessageType.CloseIn, MessageType.CloseOut:
        await m.getChannelList(initiator)[id.int].close()
      of MessageType.ResetIn, MessageType.ResetOut:
        await m.getChannelList(initiator)[id.int].reset()
      else: raise newMplexUnknownMsgError()

proc newMplex*(conn: Connection, 
               streamHandler: StreamHandler, 
               maxChanns: uint = MaxChannels): Mplex =
  new result
  result.connection = conn
  result.maxChannels = maxChanns
  result.streamHandler = streamHandler

method newStream*(m: Mplex): Future[Connection] {.gcsafe.} =
  result = m.newStream(true)

method close(m: Mplex) {.async, gcsafe.} = 
    let futs = @[allFutures(m.remote.mapIt(it.close())),
                 allFutures(m.local.mapIt(it.close()))]
    await allFutures(futs)
    await m.connection.close()

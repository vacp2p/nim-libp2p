## Nim-LibP2P
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos
import ../varint, ../connection, 
       ../vbuffer, ../protocol

const DefaultReadSize: uint = 1024

const MaxMsgSize* = 1 shl 20 # 1mb
const MaxChannels* = 1000

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

  ChannelHandler* = proc(conn: Connection) {.gcsafe.}

  Mplex* = ref object of LPProtocol
    remote*: seq[Connection]
    local*: seq[Connection]
    channelHandler*: ChannelHandler
    currentId*: uint

  Channel* = ref object of BufferStream
    id*: int
    initiator*: bool
    reset*: bool
    closedLocal*: bool
    closedRemote*: bool
    mplex*: Mplex

proc newMplexUnknownMsgError*(): ref MplexUnknownMsgError =
  result = newException(MplexUnknownMsgError, "Unknown mplex message type")

proc readLp*(conn: Connection): Future[tuple[id: uint, msgType: MessageType]] {.gcsafe.} = 
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
        break
    if res != VarintStatus.Success:
      buffer.setLen(0)
  except TransportIncompleteError:
    buffer.setLen(0)
  
  result.id = header shl 3
  result.msgType = MessageType(header and 0x7)

proc writeLp*(conn: Connection, id: uint, msgType: MessageType) {.async, gcsafe.} =
  ## write lenght prefixed
  var buf = initVBuffer()
  buf.writeVarint(LPSomeUVarint(id shl 3 or uint(msgType)))
  buf.finish()
  result = conn.write(buf.buffer)

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
proc closeRemote*(s: Channel) = discard
proc close*(s: Channel) = discard

proc newStream*(m: Mplex, 
                conn: Connection, 
                initiator: bool = true): 
                Connection {.gcsafe.}

proc newMplex*(conn: Connection, 
               handler: ChannelHandler, 
               maxChanns: uint = MaxChannels): Mplex =
  new result
  result.channelHandler = handler

proc processNewStream(m: Mplex, conn: Connection) {.async, gcsafe.} = 
  discard

proc procesMessage(m: Mplex, conn: Connection, initiator: bool) {.async, gcsafe.} = 
  discard

proc processClose(m: Mplex, conn: Connection, initiator: bool) {.async, gcsafe.} = 
  discard

proc processReset(m: Mplex, conn: Connection, initiator: bool) {.async, gcsafe.} = 
  discard 

proc newStream*(m: Mplex, 
                conn: Connection, 
                initiator: bool = true): 
                Connection {.gcsafe.} = 
  ## create new channel/stream
  let id = m.currentId
  inc(m.currentId)
  proc writeHandler(data: seq[byte]): Future[void] {.gcsafe.} = 
    let msgType = if initiator: MessageType.MsgIn else: MessageType.MsgOut
    await conn.writeLp(id, msgType) # write header
    await conn.writeLp(data) # write data

  let channel = newChannel(m, id, initiator, writeHandler)
  result = newConnection(channel)

method init(m: Mplex) =
  proc handle(conn: Connection, proto: string) {.async, closure, gcsafe.} = 
    let (id, msgType) = await conn.readLp()
    case msgType:
      of MessageType.New: 
        await m.processNewStream(conn)
      of MessageType.MsgIn, MessageType.MsgOut:
        await m.procesMessage(conn, bool(ord(msgType) and 1))
      of MessageType.CloseIn, MessageType.CloseOut:
        await m.processClose(conn, bool(ord(msgType) and 1))
      of MessageType.ResetIn, MessageType.ResetOut:
        await m.processReset(conn, bool(ord(msgType) and 1))
      else: raise newMplexUnknownMsgError()
      
  m.handler = handle

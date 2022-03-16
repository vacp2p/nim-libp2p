## Nim-LibP2P
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import std/[tables]
import chronos, chronicles, stew/endians2
import
  ../muxer,
  ../../stream/[lpstream, bufferstream]

export muxer

logScope:
  topics = "libp2p yamux"

type
  YamuxError = object of CatchableError

  YamuxChannel = ref object of BufferStream
    id: uint32
    recvWindow: int
    sendWindow: int
    maxRecvWindow: int
    conn: Connection
    opened: bool
    acked: bool

  Yamux* = ref object of Muxer
    channels: Table[uint32, YamuxChannel]
    currentId: uint32

  MsgType = enum
    Data = 0x0
    WindowUpdate = 0x1
    Ping = 0x2
    GoAway = 0x3

  MsgFlags {.size: 2.} = enum
    Syn = 0x1
    Ack = 0x2
    Fin = 0x4
    Rst = 0x8

  GoAwayStatus = enum
    NormalTermination = 0x0,
    ProtocolError = 0x1,
    InternalError = 0x2,

  YamuxHeader = object
    version: uint8
    msgType: MsgType
    flags: set[MsgFlags]
    streamId: uint32
    length: uint32

const
  YamuxVersion = 0.uint8
  DefaultWindowSize = 256000

proc readHeader(conn: LPStream): Future[YamuxHeader] {.async, gcsafe.} =
  var buffer: array[12, byte]
  await conn.readExactly(addr buffer[0], 12)

  result.version = buffer[0]
  result.msgType = MsgType(buffer[1])
  result.flags = cast[set[MsgFlags]](
    fromBytesBE(uint16, buffer[2..3])
  )
  result.streamId = fromBytesBE(uint32, buffer[4..7])
  result.length = fromBytesBE(uint32, buffer[8..11])
  return result

proc writeHeader(conn: LPStream, header: YamuxHeader): Future[void] {.gcsafe.} =
  var buffer: array[12, byte]

  buffer[0] = header.version
  buffer[1] = uint8(header.msgType)
  buffer[2..3] = toBytesBE(cast[uint16](header.flags))
  buffer[4..7] = toBytesBE(header.streamId)
  buffer[8..11] = toBytesBE(header.length)
  return conn.write(@buffer)

proc ping(T: type[YamuxHeader], pingData: uint32): T =
  T(
    version: YamuxVersion,
    msgType: MsgType.Ping,
    length: pingData
  )

proc goAway(T: type[YamuxHeader], status: GoAwayStatus): T =
  T(
    version: YamuxVersion,
    msgType: MsgType.GoAway,
    length: uint32(status)
  )

proc data(
  T: type[YamuxHeader],
  streamId: uint32,
  length: uint32 = 0,
  flags: set[MsgFlags] = {},
  ): T =
  T(
    version: YamuxVersion,
    msgType: MsgType.Data,
    length: length,
    flags: flags,
    streamId: streamId
  )

proc windowUpdate(
  T: type[YamuxHeader],
  streamId: uint32,
  delta: uint32,
  flags: set[MsgFlags] = {},
  ): T =
  T(
    version: YamuxVersion,
    msgType: MsgType.WindowUpdate,
    length: delta,
    flags: flags,
    streamId: streamId
  )

proc updateRecvWindow(channel: YamuxChannel) {.async.} =
  let inWindow = channel.recvWindow + channel.len
  if inWindow > channel.maxRecvWindow div 2:
    return

  let delta = channel.maxRecvWindow - inWindow
  channel.recvWindow.inc(delta)
  await channel.conn.writeHeader(YamuxHeader.windowUpdate(
    channel.id,
    delta.uint32
  ))

proc setMaxRecvWindow*(channel: YamuxChannel, maxRecvWindow: int) =
  channel.maxRecvWindow = maxRecvWindow

proc writeHeader(s: YamuxChannel, header: YamuxHeader) {.async.} =
  var headCopy = header
  if not s.opened:
    headCopy.flags.incl(MsgFlags.Syn)
    s.opened = true
  await s.conn.writeHeader(headCopy)

proc open*(s: YamuxChannel) {.async, gcsafe.} =
  await s.writeHeader(YamuxHeader.windowUpdate(s.id, 0))

method close*(s: YamuxChannel) {.async, gcsafe.} =
  await s.writeHeader(YamuxHeader.data(s.id, 0, {Fin}))

method write*(s: YamuxChannel, msg: seq[byte]) {.async.} =
  await s.writeHeader(YamuxHeader.data(s.id, msg.len.uint32))
  await s.conn.write(msg)

proc createStream(m: Yamux, id: uint32): YamuxChannel =
  result = YamuxChannel(
    id: id,
    maxRecvWindow: DefaultWindowSize,
    recvWindow: DefaultWindowSize,
    conn: m.connection
  )
  result.initStream()
  m.channels[id] = result
  return result

proc handleStream(m: Yamux, chann: YamuxChannel) {.async.} =
  ## call the muxer stream handler for this channel
  ##
  try:
    await m.streamHandler(chann)
    trace "finished handling stream"
    doAssert(chann.closed, "connection not closed by handler!")
  except CatchableError as exc:
    trace "Exception in yamux stream handler", msg = exc.msg
    #await chann.reset()

method handle*(m: Yamux) {.async, gcsafe.} =
  trace "Starting yamux handler"
  try:
    while not m.connection.atEof:
      trace "waiting for header"
      let header = await m.connection.readHeader()

      case header.msgType:
      of Ping:
        await m.connection.writeHeader(YamuxHeader.ping(header.length))
      of GoAway:
        raise newException(YamuxError, "Peer closed the connection")
      of Data, WindowUpdate:
        if MsgFlags.Syn in header.flags:
          if header.streamId in m.channels:
            debug "Trying to create an existing channel, skipping", id=header.streamId
          else:
            let newStream = m.createStream(header.streamId)
            newStream.opened = true
            asyncSpawn m.handleStream(newStream)
        elif header.streamId notin m.channels:
          debug "Unknown stream, skipping", id=header.streamId, typ=header.msgType
          continue

        let stream = m.channels[header.streamId]

        if header.msgType == WindowUpdate:
          stream.sendWindow += int(header.length)
        else:
          if header.length.int > stream.recvWindow.int:
            raise newException(YamuxError, "Peer exhausted the recvWindow")

          if header.length > 0:
            var buffer = newSeqUninitialized[byte](header.length)
            await m.connection.readExactly(addr buffer[0], int(header.length))
            stream.recvWindow -= int(header.length)
            await stream.pushData(buffer)
            await stream.updateRecvWindow()

        if MsgFlags.Fin in header.flags:
          await stream.pushEof()

  except YamuxError as exc:
    debug "Closing yamux connection", error=exc.msg
    await m.connection.writeHeader(YamuxHeader.goAway(ProtocolError))
  finally:
    await m.close()

method newStream*(
  m: Yamux,
  name: string = "",
  lazy: bool = false): Future[Connection] {.async, gcsafe.} =

  let stream = m.createStream(m.currentId)
  m.currentId += 2
  if not lazy:
    await stream.open()
  return stream

proc new*(T: type[Yamux], conn: Connection): T =
  T(
    connection: conn,
    currentId: if conn.transportDir == Out: 1 else: 2
  )

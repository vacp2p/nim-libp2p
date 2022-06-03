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
import chronos, chronicles, stew/[endians2, byteutils]
import
  ../muxer,
  ../../stream/connection

export muxer

logScope:
  topics = "libp2p yamux"

const
  YamuxVersion = 0.uint8
  DefaultWindowSize = 256000

type
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

proc encode(header: YamuxHeader): array[12, byte] =
  result[0] = header.version
  result[1] = uint8(header.msgType)
  result[2..3] = toBytesBE(cast[uint16](header.flags))
  result[4..7] = toBytesBE(header.streamId)
  result[8..11] = toBytesBE(header.length)

proc write(conn: LPStream, header: YamuxHeader): Future[void] {.gcsafe.} =
  var buffer = header.encode()
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

type
  YamuxChannel* = ref object of Connection
    id: uint32
    recvWindow: int
    sendWindow: int
    maxRecvWindow: int
    conn: Connection
    opened: bool
    acked: bool
    sendQueue: seq[seq[byte]]
    recvQueue: seq[seq[byte]]
    closedRemotely: Future[void]
    closedLocally: bool
    receivedData: AsyncEvent
    updatedRecvWindow: AsyncEvent

proc recvQueueBytes(y: YamuxChannel): int =
  for elem in y.recvQueue: result.inc(elem.len)

proc sendQueueBytes(y: YamuxChannel): int =
  for elem in y.sendQueue: result.inc(elem.len)

proc remoteClosed(y: YamuxChannel) =
  if y.closedRemotely.done(): return
  y.closedRemotely.complete()

proc updateRecvWindow(channel: YamuxChannel) {.async.} =
  let inWindow = channel.recvWindow + channel.recvQueueBytes()
  if inWindow > channel.maxRecvWindow div 2:
    return

  let delta = channel.maxRecvWindow - inWindow
  channel.recvWindow.inc(delta)
  await channel.conn.write(YamuxHeader.windowUpdate(
    channel.id,
    delta.uint32
  ))
  trace "increasing the recvWindow", delta

method readOnce*(
  y: YamuxChannel,
  pbytes: pointer,
  nbytes: int):
  Future[int] {.async.} =
  
  if y.recvQueue.len == 0:
    await y.closedRemotely or y.receivedData.wait()
    y.receivedData.clear()
    if y.closedRemotely.done() and y.recvQueue.len == 0:
      return 0

  let toRead = min(y.recvQueue[0].len, nbytes)

  var p = cast[ptr UncheckedArray[byte]](pbytes)
  toOpenArray(p, 0, nbytes - 1)[0..<toRead] = y.recvQueue[0].toOpenArray(0, toRead - 1)
  if toRead < y.recvQueue[0].len:
    y.recvQueue[0] = y.recvQueue[0][toRead..^1]
  else:
    y.recvQueue.delete(0)

  # We made some room in the recv buffer
  # let the peer know
  await y.updateRecvWindow()
  return toRead

proc remoteSentData(y: YamuxChannel, b: seq[byte]) {.async.} =
  y.recvWindow -= b.len
  y.recvQueue.add(b)
  y.receivedData.fire()
  await y.updateRecvWindow()

proc setMaxRecvWindow*(channel: YamuxChannel, maxRecvWindow: int) =
  channel.maxRecvWindow = maxRecvWindow

proc setupHeader(s: YamuxChannel, header: var YamuxHeader) =
  if not s.opened:
    header.flags.incl(MsgFlags.Syn)
    s.opened = true
  if not s.acked:
    header.flags.incl(MsgFlags.Ack)
    s.acked = true

proc trySend(s: YamuxChannel) {.async.} =
  if s.sendQueue.len == 0: return
  if s.sendWindow == 0:
    #TODO check queue size, kill conn if too big
    trace "send window empty"
    return

  let
    bytesAvailable = s.sendQueueBytes()
    toSend = min(s.sendWindow, bytesAvailable)
  var
    sendBuffer = newSeqUninitialized[byte](toSend + 12)
    inBuffer = 0
    header = YamuxHeader.data(s.id, toSend.uint32)

  if toSend >= bytesAvailable and s.closedLocally:
    trace "last buffer we'll sent on this channel", toSend, bytesAvailable
    header.flags.incl({Fin})

  s.setupHeader(header)

  sendBuffer[0..<12] = header.encode()

  while inBuffer < toSend:
    let bufferToSend = min(toSend - inBuffer, s.sendQueue[0].len)
    sendBuffer.toOpenArray(12, 12 + toSend - 1)[inBuffer..<(inBuffer+bufferToSend)] = s.sendQueue[0].toOpenArray(0, bufferToSend - 1)

    let remaining = s.sendQueue[0].len - bufferToSend
    if remaining <= 0:
      s.sendQueue.delete(0)
    else:
      s.sendQueue[0] = s.sendQueue[0][^remaining..^1]

    inBuffer.inc(bufferToSend)

  trace "build send buffer", len=sendBuffer.len
  s.sendWindow.dec(toSend)
  await s.conn.write(sendBuffer)

proc actuallyClose(s: YamuxChannel) {.async.} =
  if s.closedLocally and s.sendQueue.len == 0 and
    s.closedRemotely.done():
    await procCall Connection(s).closeImpl()

method closeImpl*(s: YamuxChannel) {.async, gcsafe.} =
  if s.closedLocally: return
  s.closedLocally = true

  if s.sendQueue.len == 0:
    await s.conn.write(YamuxHeader.data(s.id, 0, {Fin}))
    await s.actuallyClose()

method write*(s: YamuxChannel, msg: seq[byte]) {.async.} =
  if s.closedLocally:
    raise newLPStreamEOFError()

  s.sendQueue.add(msg)
  await s.trySend()

  while s.sendWindow == 0 and s.sendQueue.len > 0:
    # Block until there is room
    s.updatedRecvWindow.clear()
    await s.updatedRecvWindow.wait()

proc open*(s: YamuxChannel) {.async, gcsafe.} =
  # Just write an empty message, Syn will be
  # piggy-backed
  await s.write(@[])

type
  YamuxError = object of CatchableError

  Yamux* = ref object of Muxer
    channels: Table[uint32, YamuxChannel]
    currentId: uint32

proc createStream(m: Yamux, id: uint32): YamuxChannel =
  result = YamuxChannel(
    id: id,
    maxRecvWindow: DefaultWindowSize,
    recvWindow: DefaultWindowSize,
    sendWindow: DefaultWindowSize,
    conn: m.connection,
    receivedData: newAsyncEvent(),
    updatedRecvWindow: newAsyncEvent(),
    closedRemotely: newFuture[void]()
  )
  result.initStream()
  m.channels[id] = result
  trace "created channel", id
  return result

proc handleStream(m: Yamux, chann: YamuxChannel) {.async.} =
  ## call the muxer stream handler for this channel
  ##
  try:
    await m.streamHandler(chann)
    trace "finished handling stream"
    doAssert(chann.isClosed, "connection not closed by handler!")
  except CatchableError as exc:
    trace "Exception in yamux stream handler", msg = exc.msg
    #await chann.reset()

method handle*(m: Yamux) {.async, gcsafe.} =
  trace "Starting yamux handler"
  try:
    while not m.connection.atEof:
      trace "waiting for header"
      let header = await m.connection.readHeader()
      trace "got message", typ=header.msgType, len=header.length

      case header.msgType:
      of Ping:
        await m.connection.write(YamuxHeader.ping(header.length))
      of GoAway:
        raise newException(YamuxError, "Peer closed the connection")
      of Data, WindowUpdate:
        if MsgFlags.Syn in header.flags:
          if header.streamId in m.channels:
            debug "Trying to create an existing channel, skipping", id=header.streamId
          else:
            if header.streamId mod 2 == m.currentId mod 2:
              raise newException(YamuxError, "Peer used our reserved stream id")
            let newStream = m.createStream(header.streamId)
            newStream.opened = true
            asyncSpawn m.handleStream(newStream)
        elif header.streamId notin m.channels:
          debug "Unknown stream, skipping", id=header.streamId, typ=header.msgType
          continue

        let stream = m.channels[header.streamId]

        if header.msgType == WindowUpdate:
          stream.sendWindow += int(header.length)
          stream.updatedRecvWindow.fire()
          await stream.trySend()
        else:
          if header.length.int > stream.recvWindow.int:
            # check before allocating the buffer
            raise newException(YamuxError, "Peer exhausted the recvWindow")

          if header.length > 0:
            var buffer = newSeqUninitialized[byte](header.length)
            await m.connection.readExactly(addr buffer[0], int(header.length))
            await stream.remoteSentData(buffer)

        if MsgFlags.Fin in header.flags:
          trace "remote closed stream"
          stream.remoteClosed()

  except YamuxError as exc:
    debug "Closing yamux connection", error=exc.msg
    await m.connection.write(YamuxHeader.goAway(ProtocolError))
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
    currentId: if conn.dir == Out: 1 else: 2
  )

## Nim-LibP2P
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import sequtils, std/[tables]
import chronos, chronicles, stew/[endians2, byteutils, objects]
import ../muxer,
       ../../stream/connection

export muxer

logScope:
  topics = "libp2p yamux"

const
  YamuxVersion = 0.uint8
  DefaultWindowSize = 256000

type
  YamuxError = object of CatchableError

  MsgType = enum
    Data = 0x0
    WindowUpdate = 0x1
    Ping = 0x2
    GoAway = 0x3

  MsgFlags {.size: 2.} = enum
    Syn
    Ack
    Fin
    Rst

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
  let flags = fromBytesBE(uint16, buffer[2..3])
  if not result.msgType.checkedEnumAssign(buffer[1]) or flags notin 0'u16..15'u16:
     raise newException(YamuxError, "Wrong header")
  result.flags = cast[set[MsgFlags]](flags)
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

proc ping(T: type[YamuxHeader], flag: MsgFlags, pingData: uint32): T =
  T(
    version: YamuxVersion,
    msgType: MsgType.Ping,
    flags: {flag},
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
    isSrc: bool
    opened: bool
    isSending: bool
    sendQueue: seq[seq[byte]]
    recvQueue: seq[byte]
    bytesSent: uint64
    isReset: bool
    closedRemotely: Future[void]
    closedLocally: bool
    receivedData: AsyncEvent
    sentData: AsyncEvent

proc `$`(channel: YamuxChannel): string =
  result = if channel.conn.dir == Out: "=> " else: "<= "
  result &= $channel.id
  var s: seq[string] = @[]
  if channel.closedRemotely.done():
    s.add("ClosedRemotely")
  if channel.closedLocally:
    s.add("ClosedLocally")
  if channel.isReset:
    s.add("Reset")
  if s.len > 0:
    result &= " {" & s.foldl(if a != "": a & ", " & b else: b, "") & "}"

proc sendQueueBytes(channel: YamuxChannel, limit: bool = false): int =
  for elem in channel.sendQueue:
    result.inc(min(elem.len, if limit: channel.sendWindow div 3 else: elem.len))

proc actuallyClose(channel: YamuxChannel) {.async.} =
  if channel.closedLocally and channel.sendQueue.len == 0 and
     channel.closedRemotely.done():
    await procCall Connection(channel).closeImpl()

proc remoteClosed(channel: YamuxChannel) {.async.} =
  if not channel.closedRemotely.done():
    channel.closedRemotely.complete()
    await channel.actuallyClose()

method closeImpl*(channel: YamuxChannel) {.async, gcsafe.} =
  if not channel.closedLocally:
    channel.closedLocally = true

    if channel.isReset == false and channel.sendQueue.len == 0:
      await channel.conn.write(YamuxHeader.data(channel.id, 0, {Fin}))
    await channel.actuallyClose()

proc reset(channel: YamuxChannel) {.async.} =
  if not channel.isReset:
    channel.isReset = true
    channel.sendQueue = @[]
    channel.recvQueue = @[]
    channel.sendWindow = 0
    channel.recvWindow = 0
    if not channel.closedLocally:
      await channel.conn.write(YamuxHeader.data(channel.id, 0, {Rst}))
      await channel.close()
    if not channel.closedRemotely.done():
      await channel.remoteClosed()

proc updateRecvWindow(channel: YamuxChannel) {.async.} =
  let inWindow = channel.recvWindow + channel.recvQueue.len
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
  channel: YamuxChannel,
  pbytes: pointer,
  nbytes: int):
  Future[int] {.async.} =

  if channel.isReset: return 0
  if channel.recvQueue.len == 0:
    channel.receivedData.clear()
    await channel.closedRemotely or channel.receivedData.wait()
    if channel.isReset or (channel.closedRemotely.done() and channel.recvQueue.len == 0):
      return 0

  let toRead = min(channel.recvQueue.len, nbytes)

  var p = cast[ptr UncheckedArray[byte]](pbytes)
  toOpenArray(p, 0, nbytes - 1)[0..<toRead] = channel.recvQueue.toOpenArray(0, toRead - 1)
  channel.recvQueue = channel.recvQueue[toRead..^1]

  # We made some room in the recv buffer let the peer know
  await channel.updateRecvWindow()
  channel.activity = true
  return toRead

proc gotDataFromRemote(channel: YamuxChannel, b: seq[byte]) {.async.} =
  channel.recvWindow -= b.len
  channel.recvQueue = channel.recvQueue.concat(b)
  channel.receivedData.fire()
  await channel.updateRecvWindow()

proc setMaxRecvWindow*(channel: YamuxChannel, maxRecvWindow: int) =
  channel.maxRecvWindow = maxRecvWindow

proc setupHeader(channel: YamuxChannel, header: var YamuxHeader) =
  if not channel.opened and channel.isSrc:
    header.flags.incl(MsgFlags.Syn)
    channel.opened = true
  if not channel.opened and not channel.isSrc:
    header.flags.incl(MsgFlags.Ack)
    channel.opened = true

proc trySend(channel: YamuxChannel) {.async.} =
  if not channel.isSending:
    channel.isSending = true
    while channel.sendQueue.len != 0:
      if channel.sendWindow == 0:
        if channel.sendQueueBytes(true) > channel.maxRecvWindow:
          await channel.reset()
          raise newException(YamuxError, "Send queue saturated")
        trace "send window empty"
        break
      if channel.sendQueue[0].len == 0:
        var header = YamuxHeader.data(channel.id, 0)
        channel.setupHeader(header)
        let sendBuffer = toSeq(header.encode())
        channel.sendQueue.delete(0)
        await channel.conn.write(sendBuffer)
        continue

      let
        bytesAvailable = channel.sendQueueBytes()
        toSend = min(channel.sendWindow, bytesAvailable)
      var
        sendBuffer = newSeqUninitialized[byte](toSend + 12)
        header = YamuxHeader.data(channel.id, toSend.uint32)
        inBuffer = 0

      if toSend >= bytesAvailable and channel.closedLocally:
        trace "last buffer we'll sent on this channel", toSend, bytesAvailable
        header.flags.incl({Fin})

      channel.setupHeader(header)

      sendBuffer[0..<12] = header.encode()

      while inBuffer < toSend:
        let bufferToSend = min(toSend - inBuffer, channel.sendQueue[0].len)
        sendBuffer.toOpenArray(12, 12 + toSend - 1)[inBuffer..<(inBuffer+bufferToSend)] = channel.sendQueue[0].toOpenArray(0, bufferToSend - 1)
        let remaining = channel.sendQueue[0].len - bufferToSend
        if remaining <= 0:
          channel.sendQueue.delete(0)
        else:
          channel.sendQueue[0] = channel.sendQueue[0][^remaining..^1]
        inBuffer.inc(bufferToSend)

      trace "build send buffer", len=sendBuffer.len
      channel.sendWindow.dec(toSend)
      channel.bytesSent.inc(toSend)
      await channel.conn.write(sendBuffer)
      channel.activity = true
      channel.sentData.fire()
    channel.isSending = false

method write*(channel: YamuxChannel, msg: seq[byte]) {.async.} =
  if channel.closedLocally or channel.isReset:
    raise newLPStreamEOFError()

  let blockUntil = channel.bytesSent + channel.sendQueueBytes().uint64 + msg.len().uint64
  channel.sendQueue.add(msg)
  await channel.trySend()

  while blockUntil > channel.bytesSent:
    # Block until data has been sent
    channel.sentData.clear()
    await channel.sentData.wait()

proc open*(channel: YamuxChannel) {.async, gcsafe.} =
  # Just write an empty message, Syn will be piggy-backed
  await channel.write(@[])

type
  Yamux* = ref object of Muxer
    channels: Table[uint32, YamuxChannel]
    currentId: uint32
    isClosed: bool

proc cleanupChann(m: Yamux, channel: YamuxChannel) {.async.} =
  await channel.join()
  m.channels.del(channel.id)

proc createStream(m: Yamux, id: uint32, isSrc: bool): YamuxChannel =
  result = YamuxChannel(
    id: id,
    maxRecvWindow: DefaultWindowSize,
    recvWindow: DefaultWindowSize,
    sendWindow: DefaultWindowSize,
    isSrc: isSrc,
    conn: m.connection,
    receivedData: newAsyncEvent(),
    sentData: newAsyncEvent(),
    closedRemotely: newFuture[void]()
  )
  result.initStream()
  m.channels[id] = result
  asyncSpawn m.cleanupChann(result)
  trace "created channel", id

proc close*(m: Yamux) {.async.} =
  if m.isClosed == true:
    trace "Already closed", m
    return
  m.isClosed = true

  for channel in m.channels.values:
    await channel.reset()
  await m.connection.write(YamuxHeader.goAway(NormalTermination))
  await m.connection.close()

proc handleStream(m: Yamux, channel: YamuxChannel) {.async.} =
  ## call the muxer stream handler for this channel
  ##
  try:
    await m.streamHandler(channel)
    trace "finished handling stream"
    doAssert(channel.isClosed, "connection not closed by handler!")
  except CatchableError as exc:
    trace "Exception in yamux stream handler", msg = exc.msg
    await channel.reset()

method handle*(m: Yamux) {.async, gcsafe.} =
  trace "Starting yamux handler"
  try:
    while not m.connection.atEof:
      trace "waiting for header"
      let header = await m.connection.readHeader()
      trace "got message", typ=header.msgType, len=header.length

      case header.msgType:
      of Ping:
        if MsgFlags.Syn in header.flags:
          await m.connection.write(YamuxHeader.ping(MsgFlags.Ack, header.length))
      of GoAway:
        var status: GoAwayStatus
        if status.checkedEnumAssign(header.length): trace "Received go away", status
        else: trace "Received unexpected error go away"
        break
      of Data, WindowUpdate:
        if MsgFlags.Syn in header.flags:
          if header.streamId in m.channels:
            debug "Trying to create an existing channel, skipping", id=header.streamId
          else:
            if header.streamId mod 2 == m.currentId mod 2:
              raise newException(YamuxError, "Peer used our reserved stream id")
            let newStream = m.createStream(header.streamId, false)
            newStream.opened = true
            asyncSpawn m.handleStream(newStream)
        elif header.streamId notin m.channels:
          raise newException(YamuxError, "Unknown stream ID: " & $header.streamId)

        let channel = m.channels[header.streamId]

        if header.msgType == WindowUpdate:
          channel.sendWindow += int(header.length)
          await channel.trySend()
        else:
          if header.length.int > channel.recvWindow.int:
            # check before allocating the buffer
            raise newException(YamuxError, "Peer exhausted the recvWindow")

          if header.length > 0:
            var buffer = newSeqUninitialized[byte](header.length)
            await m.connection.readExactly(addr buffer[0], int(header.length))
            if channel.isReset:
              channel.recvWindow.inc(buffer.len)
              if channel.recvWindow > channel.maxRecvWindow:
                raise newException(YamuxError, "Peer didn't stop sending msg after reset")
            else:
              await channel.gotDataFromRemote(buffer)

        if MsgFlags.Fin in header.flags:
          trace "remote closed channel"
          await channel.remoteClosed()
        if MsgFlags.Rst in header.flags:
          trace "remote reset channel"
          channel.isReset = true
          await channel.remoteClosed()
          await channel.close()

  except YamuxError as exc:
    trace "Closing yamux connection", error=exc.msg
    await m.connection.write(YamuxHeader.goAway(ProtocolError))
  finally:
    await m.close()

method newStream*(
  m: Yamux,
  name: string = "",
  lazy: bool = false): Future[Connection] {.async, gcsafe.} =

  let stream = m.createStream(m.currentId, true)
  m.currentId += 2
  if not lazy:
    await stream.open()
  return stream

proc new*(T: type[Yamux], conn: Connection): T =
  T(
    connection: conn,
    currentId: if conn.dir == Out: 1 else: 2
  )

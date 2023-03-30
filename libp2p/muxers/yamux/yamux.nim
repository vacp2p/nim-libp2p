# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import sequtils, std/[tables]
import chronos, chronicles, metrics, stew/[endians2, byteutils, objects]
import ../muxer,
       ../../stream/connection

export muxer

logScope:
  topics = "libp2p yamux"

const
  YamuxCodec* = "/yamux/1.0.0"
  YamuxVersion = 0.uint8
  DefaultWindowSize = 256000
  MaxChannelCount = 200

when defined(libp2p_yamux_metrics):
  declareGauge(libp2p_yamux_channels, "yamux channels", labels = ["initiator", "peer"])
  declareHistogram libp2p_yamux_send_queue, "message send queue length (in byte)",
    buckets = [0.0, 100.0, 250.0, 1000.0, 2000.0, 1600.0, 6400.0, 25600.0, 256000.0]
  declareHistogram libp2p_yamux_recv_queue, "message recv queue length (in byte)",
    buckets = [0.0, 100.0, 250.0, 1000.0, 2000.0, 1600.0, 6400.0, 25600.0, 256000.0]

type
  YamuxError* = object of CatchableError

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

proc `$`(header: YamuxHeader): string =
  result = "{" & $header.msgType & ", "
  result &= "{" & header.flags.foldl(if a != "": a & ", " & $b else: $b, "") & "}, "
  result &= "streamId: " & $header.streamId & ", "
  result &= "length: " & $header.length & "}"

proc encode(header: YamuxHeader): array[12, byte] =
  result[0] = header.version
  result[1] = uint8(header.msgType)
  result[2..3] = toBytesBE(cast[uint16](header.flags))
  result[4..7] = toBytesBE(header.streamId)
  result[8..11] = toBytesBE(header.length)

proc write(conn: LPStream, header: YamuxHeader): Future[void] {.gcsafe.} =
  trace "write directly on stream", h = $header
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
  ToSend = tuple
    data: seq[byte]
    sent: int
    fut: Future[void]
  YamuxChannel* = ref object of Connection
    id: uint32
    recvWindow: int
    sendWindow: int
    maxRecvWindow: int
    conn: Connection
    isSrc: bool
    opened: bool
    isSending: bool
    sendQueue: seq[ToSend]
    recvQueue: seq[byte]
    isReset: bool
    remoteReset: bool
    closedRemotely: Future[void]
    closedLocally: bool
    receivedData: AsyncEvent
    returnedEof: bool

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
  for (elem, sent, _) in channel.sendQueue:
    result.inc(min(elem.len - sent, if limit: channel.maxRecvWindow div 3 else: elem.len - sent))

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

proc reset(channel: YamuxChannel, isLocal: bool = false) {.async.} =
  if channel.isReset:
    return
  trace "Reset channel"
  channel.isReset = true
  channel.remoteReset = not isLocal
  for (d, s, fut) in channel.sendQueue:
    fut.fail(newLPStreamEOFError())
  channel.sendQueue = @[]
  channel.recvQueue = @[]
  channel.sendWindow = 0
  if not channel.closedLocally:
    if isLocal:
      try: await channel.conn.write(YamuxHeader.data(channel.id, 0, {Rst}))
      except LPStreamEOFError as exc: discard
      except LPStreamClosedError as exc: discard
    await channel.close()
  if not channel.closedRemotely.done():
    await channel.remoteClosed()
  channel.receivedData.fire()
  if not isLocal:
    # If we reset locally, we want to flush up to a maximum of recvWindow
    # bytes. We use the recvWindow in the proc cleanupChann.
    channel.recvWindow = 0

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

  if channel.isReset:
    raise if channel.remoteReset:
        newLPStreamResetError()
      elif channel.closedLocally:
        newLPStreamClosedError()
      else:
        newLPStreamConnDownError()
  if channel.returnedEof:
    raise newLPStreamRemoteClosedError()
  if channel.recvQueue.len == 0:
    channel.receivedData.clear()
    await channel.closedRemotely or channel.receivedData.wait()
    if channel.closedRemotely.done() and channel.recvQueue.len == 0:
      channel.returnedEof = true
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
  when defined(libp2p_yamux_metrics):
    libp2p_yamux_recv_queue.observe(channel.recvQueue.len.int64)
  await channel.updateRecvWindow()

proc setMaxRecvWindow*(channel: YamuxChannel, maxRecvWindow: int) =
  channel.maxRecvWindow = maxRecvWindow

proc trySend(channel: YamuxChannel) {.async.} =
  if channel.isSending:
    return
  channel.isSending = true
  defer: channel.isSending = false
  while channel.sendQueue.len != 0:
    channel.sendQueue.keepItIf(not (it.fut.cancelled() and it.sent == 0))
    if channel.sendWindow == 0:
      trace "send window empty"
      if channel.sendQueueBytes(true) > channel.maxRecvWindow:
        debug "channel send queue too big, resetting", maxSendWindow=channel.maxRecvWindow,
          currentQueueSize = channel.sendQueueBytes(true)
        try:
          await channel.reset(true)
        except CatchableError as exc:
          debug "failed to reset", msg=exc.msg
      break

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

    sendBuffer[0..<12] = header.encode()

    var futures: seq[Future[void]]
    while inBuffer < toSend:
      let (data, sent, fut) = channel.sendQueue[0]
      let bufferToSend = min(data.len - sent, toSend - inBuffer)
      sendBuffer.toOpenArray(12, 12 + toSend - 1)[inBuffer..<(inBuffer+bufferToSend)] =
        channel.sendQueue[0].data.toOpenArray(sent, sent + bufferToSend - 1)
      channel.sendQueue[0].sent.inc(bufferToSend)
      if channel.sendQueue[0].sent >= data.len:
        futures.add(fut)
        channel.sendQueue.delete(0)
      inBuffer.inc(bufferToSend)

    trace "build send buffer", h = $header, msg=string.fromBytes(sendBuffer[12..^1])
    channel.sendWindow.dec(toSend)
    try: await channel.conn.write(sendBuffer)
    except CatchableError as exc:
      let connDown = newLPStreamConnDownError(exc)
      for fut in futures.items():
        fut.fail(connDown)
      await channel.reset()
      break
    for fut in futures.items():
      fut.complete()
    channel.activity = true

method write*(channel: YamuxChannel, msg: seq[byte]): Future[void] =
  result = newFuture[void]("Yamux Send")
  if channel.remoteReset:
    result.fail(newLPStreamResetError())
    return result
  if channel.closedLocally or channel.isReset:
    result.fail(newLPStreamClosedError())
    return result
  if msg.len == 0:
    result.complete()
    return result
  channel.sendQueue.add((msg, 0, result))
  when defined(libp2p_yamux_metrics):
    libp2p_yamux_recv_queue.observe(channel.sendQueueBytes().int64)
  asyncSpawn channel.trySend()

proc open*(channel: YamuxChannel) {.async, gcsafe.} =
  if channel.opened:
    trace "Try to open channel twice"
    return
  channel.opened = true
  await channel.conn.write(YamuxHeader.data(channel.id, 0, {if channel.isSrc: Syn else: Ack}))

method getWrapped*(channel: YamuxChannel): Connection = channel.conn

type
  Yamux* = ref object of Muxer
    channels: Table[uint32, YamuxChannel]
    flushed: Table[uint32, int]
    currentId: uint32
    isClosed: bool
    maxChannCount: int

proc lenBySrc(m: Yamux, isSrc: bool): int =
  for v in m.channels.values():
    if v.isSrc == isSrc: result += 1

proc cleanupChann(m: Yamux, channel: YamuxChannel) {.async.} =
  await channel.join()
  m.channels.del(channel.id)
  when defined(libp2p_yamux_metrics):
    libp2p_yamux_channels.set(m.lenBySrc(channel.isSrc).int64, [$channel.isSrc, $channel.peerId])
  if channel.isReset and channel.recvWindow > 0:
    m.flushed[channel.id] = channel.recvWindow

proc createStream(m: Yamux, id: uint32, isSrc: bool): YamuxChannel =
  result = YamuxChannel(
    id: id,
    maxRecvWindow: DefaultWindowSize,
    recvWindow: DefaultWindowSize,
    sendWindow: DefaultWindowSize,
    isSrc: isSrc,
    conn: m.connection,
    receivedData: newAsyncEvent(),
    closedRemotely: newFuture[void]()
  )
  result.objName = "YamuxStream"
  result.dir = if isSrc: Direction.Out else: Direction.In
  result.timeoutHandler = proc(): Future[void] {.gcsafe.} =
    trace "Idle timeout expired, resetting YamuxChannel"
    result.reset()
  result.initStream()
  result.peerId = m.connection.peerId
  result.observedAddr = m.connection.observedAddr
  result.transportDir = m.connection.transportDir
  when defined(libp2p_agents_metrics):
    result.shortAgent = m.connection.shortAgent
  m.channels[id] = result
  asyncSpawn m.cleanupChann(result)
  trace "created channel", id, pid=m.connection.peerId
  when defined(libp2p_yamux_metrics):
    libp2p_yamux_channels.set(m.lenBySrc(isSrc).int64, [$isSrc, $result.peerId])

method close*(m: Yamux) {.async.} =
  if m.isClosed == true:
    trace "Already closed"
    return
  m.isClosed = true

  trace "Closing yamux"
  let channels = toSeq(m.channels.values())
  for channel in channels:
    await channel.reset(true)
  try: await m.connection.write(YamuxHeader.goAway(NormalTermination))
  except CatchableError as exc: trace "failed to send goAway", msg=exc.msg
  await m.connection.close()
  trace "Closed yamux"

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
  trace "Starting yamux handler", pid=m.connection.peerId
  try:
    while not m.connection.atEof:
      trace "waiting for header"
      let header = await m.connection.readHeader()
      trace "got message", h = $header

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
            if header.streamId in m.flushed:
              m.flushed.del(header.streamId)
            if header.streamId mod 2 == m.currentId mod 2:
              raise newException(YamuxError, "Peer used our reserved stream id")
            let newStream = m.createStream(header.streamId, false)
            if m.channels.len >= m.maxChannCount:
              await newStream.reset()
              continue
            await newStream.open()
            asyncSpawn m.handleStream(newStream)
        elif header.streamId notin m.channels:
          if header.streamId notin m.flushed:
            raise newException(YamuxError, "Unknown stream ID: " & $header.streamId)
          elif header.msgType == Data:
            # Flush the data
            m.flushed[header.streamId].dec(int(header.length))
            if m.flushed[header.streamId] < 0:
              raise newException(YamuxError, "Peer exhausted the recvWindow after reset")
            if header.length > 0:
              var buffer = newSeqUninitialized[byte](header.length)
              await m.connection.readExactly(addr buffer[0], int(header.length))
          continue

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
            trace "Msg Rcv", msg=string.fromBytes(buffer)
            await channel.gotDataFromRemote(buffer)

        if MsgFlags.Fin in header.flags:
          trace "remote closed channel"
          await channel.remoteClosed()
        if MsgFlags.Rst in header.flags:
          trace "remote reset channel"
          await channel.reset()
  except LPStreamEOFError as exc:
    trace "Stream EOF", msg = exc.msg
  except YamuxError as exc:
    trace "Closing yamux connection", error=exc.msg
    await m.connection.write(YamuxHeader.goAway(ProtocolError))
  finally:
    await m.close()
  trace "Stopped yamux handler"

method getStreams*(m: Yamux): seq[Connection] =
  for c in m.channels.values: result.add(c)

method newStream*(
  m: Yamux,
  name: string = "",
  lazy: bool = false): Future[Connection] {.async, gcsafe.} =

  if m.channels.len > m.maxChannCount - 1:
    raise newException(TooManyChannels, "max allowed channel count exceeded")
  let stream = m.createStream(m.currentId, true)
  m.currentId += 2
  if not lazy:
    await stream.open()
  return stream

proc new*(T: type[Yamux], conn: Connection, maxChannCount: int = MaxChannelCount): T =
  T(
    connection: conn,
    currentId: if conn.dir == Out: 1 else: 2,
    maxChannCount: maxChannCount
  )

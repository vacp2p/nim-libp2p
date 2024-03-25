# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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
  YamuxDefaultWindowSize* = 256000
  MaxSendQueueSize = 256000
  MaxChannelCount = 200

when defined(libp2p_yamux_metrics):
  declareGauge libp2p_yamux_channels,
    "yamux channels", labels = ["initiator", "peer"]
  declareHistogram libp2p_yamux_send_queue,
    "message send queue length (in byte)", buckets = [
      0.0, 100.0, 250.0, 1000.0, 2000.0, 3200.0, 6400.0, 25600.0, 256000.0]
  declareHistogram libp2p_yamux_recv_queue,
    "message recv queue length (in byte)", buckets = [
      0.0, 100.0, 250.0, 1000.0, 2000.0, 3200.0, 6400.0, 25600.0, 256000.0]

type
  YamuxError* = object of MuxerError

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

proc readHeader(
    conn: LPStream
): Future[YamuxHeader] {.async: (raises: [
    CancelledError, LPStreamError, MuxerError]).} =
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
  "{" & $header.msgType & ", " &
  "{" & header.flags.foldl(if a != "": a & ", " & $b else: $b, "") & "}, " &
  "streamId: " & $header.streamId & ", " &
  "length: " & $header.length & "}"

proc encode(header: YamuxHeader): array[12, byte] =
  result[0] = header.version
  result[1] = uint8(header.msgType)
  result[2..3] = toBytesBE(uint16(cast[uint8](header.flags))) # workaround https://github.com/nim-lang/Nim/issues/21789
  result[4..7] = toBytesBE(header.streamId)
  result[8..11] = toBytesBE(header.length)

proc write(
    conn: LPStream,
    header: YamuxHeader
): Future[void] {.async: (raises: [
    CancelledError, LPStreamError], raw: true).} =
  trace "write directly on stream", h = $header
  var buffer = header.encode()
  conn.write(@buffer)

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
    flags: set[MsgFlags] = {}): T =
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
    flags: set[MsgFlags] = {}): T =
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
    fut: Future[void].Raising([CancelledError, LPStreamError])
  YamuxChannel* = ref object of Connection
    id: uint32
    recvWindow: int
    sendWindow: int
    maxRecvWindow: int
    maxSendQueueSize: int
    conn: Connection
    isSrc: bool
    opened: bool
    isSending: bool
    sendQueue: seq[ToSend]
    recvQueue: seq[byte]
    isReset: bool
    remoteReset: bool
    closedRemotely: Future[void].Raising([])
    closedLocally: bool
    receivedData: AsyncEvent
    returnedEof: bool

proc `$`(channel: YamuxChannel): string =
  result = if channel.conn.dir == Out: "=> " else: "<= "
  result &= $channel.id
  var s: seq[string] = @[]
  if channel.closedRemotely.completed():
    s.add("ClosedRemotely")
  if channel.closedLocally:
    s.add("ClosedLocally")
  if channel.isReset:
    s.add("Reset")
  if s.len > 0:
    result &= " {" & s.foldl(if a != "": a & ", " & b else: b, "") & "}"

proc lengthSendQueue(channel: YamuxChannel): int =
  ## Returns the length of what remains to be sent
  ##
  channel.sendQueue.foldl(a + b.data.len - b.sent, 0)

proc lengthSendQueueWithLimit(channel: YamuxChannel): int =
  ## Returns the length of what remains to be sent, but limit the size of big messages.
  ##
  # For leniency, limit big messages size to the third of maxSendQueueSize
  # This value is arbitrary, it's not in the specs, it permits to store up to
  # 3 big messages if the peer is stalling.
  channel.sendQueue.foldl(a + min(b.data.len - b.sent, channel.maxSendQueueSize div 3), 0)

proc actuallyClose(channel: YamuxChannel) {.async: (raises: []).} =
  if channel.closedLocally and channel.sendQueue.len == 0 and
     channel.closedRemotely.completed():
    await procCall Connection(channel).closeImpl()

proc remoteClosed(channel: YamuxChannel) {.async: (raises: []).} =
  if not channel.closedRemotely.completed():
    channel.closedRemotely.complete()
    await channel.actuallyClose()

method closeImpl*(channel: YamuxChannel) {.async: (raises: []).} =
  if not channel.closedLocally:
    channel.closedLocally = true
    channel.isEof = true

    if not channel.isReset and channel.sendQueue.len == 0:
      try: await channel.conn.write(YamuxHeader.data(channel.id, 0, {Fin}))
      except CancelledError, LPStreamError: discard
    await channel.actuallyClose()

proc reset(
    channel: YamuxChannel, isLocal: bool = false) {.async: (raises: []).} =
  # If we reset locally, we want to flush up to a maximum of recvWindow
  # bytes. It's because the peer we're connected to can send us data before
  # it receives the reset.
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
    if isLocal and not channel.isSending:
      try: await channel.conn.write(YamuxHeader.data(channel.id, 0, {Rst}))
      except CancelledError, LPStreamError: discard
    await channel.close()
  if not channel.closedRemotely.completed():
    await channel.remoteClosed()
  channel.receivedData.fire()
  if not isLocal:
    # If the reset is remote, there's no reason to flush anything.
    channel.recvWindow = 0

proc updateRecvWindow(
    channel: YamuxChannel
) {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Send to the peer a window update when the recvWindow is empty enough
  ##
  # In order to avoid spamming a window update everytime a byte is read,
  # we send it everytime half of the maxRecvWindow is read.
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
    nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Read from a yamux channel

  if channel.isReset:
    raise
      if channel.remoteReset:
        newLPStreamResetError()
      elif channel.closedLocally:
        newLPStreamClosedError()
      else:
        newLPStreamConnDownError()
  if channel.returnedEof:
    raise newLPStreamRemoteClosedError()
  if channel.recvQueue.len == 0:
    channel.receivedData.clear()
    try:  # https://github.com/status-im/nim-chronos/issues/516
      discard await race(channel.closedRemotely, channel.receivedData.wait())
    except ValueError: raiseAssert("Futures list is not empty")
    if channel.closedRemotely.completed() and channel.recvQueue.len == 0:
      channel.returnedEof = true
      channel.isEof = true
      return 0

  let toRead = min(channel.recvQueue.len, nbytes)

  var p = cast[ptr UncheckedArray[byte]](pbytes)
  toOpenArray(p, 0, nbytes - 1)[0..<toRead] =
    channel.recvQueue.toOpenArray(0, toRead - 1)
  channel.recvQueue = channel.recvQueue[toRead..^1]

  # We made some room in the recv buffer let the peer know
  await channel.updateRecvWindow()
  channel.activity = true
  return toRead

proc gotDataFromRemote(
    channel: YamuxChannel,
    b: seq[byte]) {.async: (raises: [CancelledError, LPStreamError]).} =
  channel.recvWindow -= b.len
  channel.recvQueue = channel.recvQueue.concat(b)
  channel.receivedData.fire()
  when defined(libp2p_yamux_metrics):
    libp2p_yamux_recv_queue.observe(channel.recvQueue.len.int64)
  await channel.updateRecvWindow()

proc setMaxRecvWindow*(channel: YamuxChannel, maxRecvWindow: int) =
  channel.maxRecvWindow = maxRecvWindow

proc trySend(
    channel: YamuxChannel
) {.async: (raises: [CancelledError, LPStreamError]).} =
  if channel.isSending:
    return
  channel.isSending = true
  defer: channel.isSending = false

  while channel.sendQueue.len != 0:
    channel.sendQueue.keepItIf(not (it.fut.cancelled() and it.sent == 0))
    if channel.sendWindow == 0:
      trace "trying to send while the sendWindow is empty"
      if channel.lengthSendQueueWithLimit() > channel.maxSendQueueSize:
        trace "channel send queue too big, resetting",
          maxSendQueueSize = channel.maxSendQueueSize,
          currentQueueSize = channel.lengthSendQueueWithLimit()
        await channel.reset(isLocal = true)
      break

    let
      bytesAvailable = channel.lengthSendQueue()
      toSend = min(channel.sendWindow, bytesAvailable)
    var
      sendBuffer = newSeqUninitialized[byte](toSend + 12)
      header = YamuxHeader.data(channel.id, toSend.uint32)
      inBuffer = 0

    if toSend >= bytesAvailable and channel.closedLocally:
      trace "last buffer we'll sent on this channel", toSend, bytesAvailable
      header.flags.incl({Fin})

    sendBuffer[0..<12] = header.encode()

    var futures: seq[Future[void].Raising([CancelledError, LPStreamError])]
    while inBuffer < toSend:
      # concatenate the different message we try to send into one buffer
      let (data, sent, fut) = channel.sendQueue[0]
      let bufferToSend = min(data.len - sent, toSend - inBuffer)
      sendBuffer.toOpenArray(12, 12 + toSend - 1)[inBuffer..<(inBuffer+bufferToSend)] =
        channel.sendQueue[0].data.toOpenArray(sent, sent + bufferToSend - 1)
      channel.sendQueue[0].sent.inc(bufferToSend)
      if channel.sendQueue[0].sent >= data.len:
        # if every byte of the message is in the buffer, add the write future to the
        # sequence of futures to be completed (or failed) when the buffer is sent
        futures.add(fut)
        channel.sendQueue.delete(0)
      inBuffer.inc(bufferToSend)

    trace "try to send the buffer", h = $header
    channel.sendWindow.dec(toSend)
    try:
      await channel.conn.write(sendBuffer)
    except CancelledError:
      trace "cancelled sending the buffer"
      for fut in futures.items():
        fut.cancelSoon()
      await channel.reset()
      break
    except LPStreamError as exc:
      trace "failed to send the buffer"
      let connDown = newLPStreamConnDownError(exc)
      for fut in futures.items():
        fut.fail(connDown)
      await channel.reset()
      break
    for fut in futures.items():
      fut.complete()
    channel.activity = true

method write*(
    channel: YamuxChannel,
    msg: seq[byte]
): Future[void] {.async: (raises: [
    CancelledError, LPStreamError], raw: true).} =
  ## Write to yamux channel
  ##
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
    libp2p_yamux_send_queue.observe(channel.lengthSendQueue().int64)
  asyncSpawn channel.trySend()

proc open(
    channel: YamuxChannel
) {.async: (raises: [CancelledError, LPStreamError]).} =
  ## Open a yamux channel by sending a window update with Syn or Ack flag
  ##
  if channel.opened:
    trace "Try to open channel twice"
    return
  channel.opened = true
  await channel.conn.write(YamuxHeader.windowUpdate(
    channel.id,
    uint32(max(channel.maxRecvWindow - YamuxDefaultWindowSize, 0)),
    {if channel.isSrc: Syn else: Ack}))

method getWrapped*(channel: YamuxChannel): Connection = channel.conn

type
  Yamux* = ref object of Muxer
    channels: Table[uint32, YamuxChannel]
    flushed: Table[uint32, int]
    currentId: uint32
    isClosed: bool
    maxChannCount: int
    windowSize: int
    maxSendQueueSize: int
    inTimeout: Duration
    outTimeout: Duration

proc lenBySrc(m: Yamux, isSrc: bool): int =
  for v in m.channels.values():
    if v.isSrc == isSrc: result += 1

proc cleanupChannel(m: Yamux, channel: YamuxChannel) {.async: (raises: []).} =
  try:
    await channel.join()
  except CancelledError:
    discard
  m.channels.del(channel.id)
  when defined(libp2p_yamux_metrics):
    libp2p_yamux_channels.set(
      m.lenBySrc(channel.isSrc).int64, [$channel.isSrc, $channel.peerId])
  if channel.isReset and channel.recvWindow > 0:
    m.flushed[channel.id] = channel.recvWindow

proc createStream(
    m: Yamux, id: uint32, isSrc: bool,
    recvWindow: int, maxSendQueueSize: int): YamuxChannel =
  # During initialization, recvWindow can be larger than maxRecvWindow.
  # This is because the peer we're connected to will always assume
  # that the initial recvWindow is 256k.
  # To solve this contradiction, no updateWindow will be sent until
  # recvWindow is less than maxRecvWindow
  proc newClosedRemotelyFut(): Future[void] {.async: (raises: [], raw: true).} =
    newFuture[void]()
  var stream = YamuxChannel(
    id: id,
    maxRecvWindow: recvWindow,
    recvWindow: if recvWindow > YamuxDefaultWindowSize: recvWindow else: YamuxDefaultWindowSize,
    sendWindow: YamuxDefaultWindowSize,
    maxSendQueueSize: maxSendQueueSize,
    isSrc: isSrc,
    conn: m.connection,
    receivedData: newAsyncEvent(),
    closedRemotely: newClosedRemotelyFut()
  )
  stream.objName = "YamuxStream"
  if isSrc:
    stream.dir = Direction.Out
    stream.timeout = m.outTimeout
  else:
    stream.dir = Direction.In
    stream.timeout = m.inTimeout
  stream.timeoutHandler =
    proc(): Future[void] {.async: (raises: [], raw: true).} =
      trace "Idle timeout expired, resetting YamuxChannel"
      stream.reset(isLocal = true)
  stream.initStream()
  stream.peerId = m.connection.peerId
  stream.observedAddr = m.connection.observedAddr
  stream.transportDir = m.connection.transportDir
  when defined(libp2p_agents_metrics):
    stream.shortAgent = m.connection.shortAgent
  m.channels[id] = stream
  asyncSpawn m.cleanupChannel(stream)
  trace "created channel", id, pid=m.connection.peerId
  when defined(libp2p_yamux_metrics):
    libp2p_yamux_channels.set(m.lenBySrc(isSrc).int64, [$isSrc, $stream.peerId])
  return stream

method close*(m: Yamux) {.async: (raises: []).} =
  if m.isClosed == true:
    trace "Already closed"
    return
  m.isClosed = true

  trace "Closing yamux"
  let channels = toSeq(m.channels.values())
  for channel in channels:
    await channel.reset(isLocal = true)
  try: await m.connection.write(YamuxHeader.goAway(NormalTermination))
  except CancelledError as exc: trace "cancelled sending goAway", msg = exc.msg
  except LPStreamError as exc: trace "failed to send goAway", msg = exc.msg
  await m.connection.close()
  trace "Closed yamux"

proc handleStream(m: Yamux, channel: YamuxChannel) {.async: (raises: []).} =
  ## Call the muxer stream handler for this channel
  ##
  await m.streamHandler(channel)
  trace "finished handling stream"
  doAssert(channel.isClosed, "connection not closed by handler!")

method handle*(m: Yamux) {.async: (raises: []).} =
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
              debug "Peer used our reserved stream id, skipping", id=header.streamId, currentId=m.currentId, peerId=m.connection.peerId
              raise newException(YamuxError, "Peer used our reserved stream id")
            let newStream = m.createStream(header.streamId, false, m.windowSize, m.maxSendQueueSize)
            if m.channels.len >= m.maxChannCount:
              await newStream.reset()
              continue
            await newStream.open()
            asyncSpawn m.handleStream(newStream)
        elif header.streamId notin m.channels:
          # Flush the data
          m.flushed.withValue(header.streamId, flushed):
            if header.msgType == Data:
              flushed[].dec(int(header.length))
              if flushed[] < 0:
                raise newException(YamuxError,
                  "Peer exhausted the recvWindow after reset")
              if header.length > 0:
                var buffer = newSeqUninitialized[byte](header.length)
                await m.connection.readExactly(
                  addr buffer[0], int(header.length))
          do:
            raise newException(YamuxError,
              "Unknown stream ID: " & $header.streamId)
          continue

        let channel =
          try:
            m.channels[header.streamId]
          except KeyError:
            raise newException(YamuxError,
              "Stream was cleaned up before handling data: " & $header.streamId)

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
            trace "Msg Rcv", msg=shortLog(buffer)
            await channel.gotDataFromRemote(buffer)

        if MsgFlags.Fin in header.flags:
          trace "remote closed channel"
          await channel.remoteClosed()
        if MsgFlags.Rst in header.flags:
          trace "remote reset channel"
          await channel.reset()
  except CancelledError as exc:
    debug "Unexpected cancellation in yamux handler", msg = exc.msg
  except LPStreamEOFError as exc:
    trace "Stream EOF", msg = exc.msg
  except LPStreamError as exc:
    debug "Unexpected stream exception in yamux read loop", msg = exc.msg
  except YamuxError as exc:
    trace "Closing yamux connection", error=exc.msg
    try:
      await m.connection.write(YamuxHeader.goAway(ProtocolError))
    except CancelledError, LPStreamError:
      discard
  except MuxerError as exc:
    debug "Unexpected muxer exception in yamux read loop", msg = exc.msg
    try:
      await m.connection.write(YamuxHeader.goAway(ProtocolError))
    except CancelledError, LPStreamError:
      discard
  finally:
    await m.close()
  trace "Stopped yamux handler"

method getStreams*(m: Yamux): seq[Connection] =
  for c in m.channels.values: result.add(c)

method newStream*(
    m: Yamux,
    name: string = "",
    lazy: bool = false
): Future[Connection] {.async: (raises: [
    CancelledError, LPStreamError, MuxerError]).} =
  if m.channels.len > m.maxChannCount - 1:
    raise newException(TooManyChannels, "max allowed channel count exceeded")
  let stream = m.createStream(m.currentId, true, m.windowSize, m.maxSendQueueSize)
  m.currentId += 2
  if not lazy:
    await stream.open()
  return stream

proc new*(
    T: type[Yamux], conn: Connection,
    maxChannCount: int = MaxChannelCount,
    windowSize: int = YamuxDefaultWindowSize,
    maxSendQueueSize: int = MaxSendQueueSize,
    inTimeout: Duration = 5.minutes,
    outTimeout: Duration = 5.minutes): T =
  T(
    connection: conn,
    currentId: if conn.dir == Out: 1 else: 2,
    maxChannCount: maxChannCount,
    windowSize: windowSize,
    maxSendQueueSize: maxSendQueueSize,
    inTimeout: inTimeout,
    outTimeout: outTimeout
  )

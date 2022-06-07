## Nim-LibP2P
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import options
import sequtils, strutils, tables
import chronos, chronicles

import ../peerinfo,
       ../switch,
       ../multiaddress,
       ../stream/connection,
       ../protocols/protocol,
       ../transports/transport,
       ../utility,
       ../errors

const
  RelayCodec* = "/libp2p/circuit/relay/0.1.0"
  MsgSize* = 4096
  MaxCircuit* = 1024
  MaxCircuitPerPeer* = 64

logScope:
  topics = "libp2p relay"

type
  RelayType* = enum
    Hop = 1
    Stop = 2
    Status = 3
    CanHop = 4
  RelayStatus* = enum
    Success = 100
    HopSrcAddrTooLong = 220
    HopDstAddrTooLong = 221
    HopSrcMultiaddrInvalid = 250
    HopDstMultiaddrInvalid = 251
    HopNoConnToDst = 260
    HopCantDialDst = 261
    HopCantOpenDstStream = 262
    HopCantSpeakRelay = 270
    HopCantRelayToSelf = 280
    StopSrcAddrTooLong = 320
    StopDstAddrTooLong = 321
    StopSrcMultiaddrInvalid = 350
    StopDstMultiaddrInvalid = 351
    StopRelayRefused = 390
    MalformedMessage = 400

  RelayError* = object of LPError

  RelayPeer* = object
    peerId*: PeerID
    addrs*: seq[MultiAddress]

  AddConn* = proc(conn: Connection): Future[void] {.gcsafe, raises: [Defect].}

  RelayMessage* = object
    msgType*: Option[RelayType]
    srcPeer*: Option[RelayPeer]
    dstPeer*: Option[RelayPeer]
    status*: Option[RelayStatus]

  Relay* = ref object of LPProtocol
    switch*: Switch
    peerId: PeerID
    dialer: Dial
    canHop: bool
    streamCount: int
    hopCount: CountTable[PeerId]

    addConn: AddConn

    maxCircuit*: int
    maxCircuitPerPeer*: int
    msgSize*: int

proc encodeMsg*(msg: RelayMessage): ProtoBuffer =
  result = initProtoBuffer()

  if isSome(msg.msgType):
    result.write(1, msg.msgType.get().ord.uint)
  if isSome(msg.srcPeer):
    var peer = initProtoBuffer()
    peer.write(1, msg.srcPeer.get().peerId)
    for ma in msg.srcPeer.get().addrs:
      peer.write(2, ma.data.buffer)
    peer.finish()
    result.write(2, peer.buffer)
  if isSome(msg.dstPeer):
    var peer = initProtoBuffer()
    peer.write(1, msg.dstPeer.get().peerId)
    for ma in msg.dstPeer.get().addrs:
      peer.write(2, ma.data.buffer)
    peer.finish()
    result.write(3, peer.buffer)
  if isSome(msg.status):
    result.write(4, msg.status.get().ord.uint)

  result.finish()

proc decodeMsg*(buf: seq[byte]): Option[RelayMessage] =
  var
    rMsg: RelayMessage
    msgTypeOrd: uint32
    src: RelayPeer
    dst: RelayPeer
    statusOrd: uint32
    pbSrc: ProtoBuffer
    pbDst: ProtoBuffer

  let
    pb = initProtoBuffer(buf)
    r1 = pb.getField(1, msgTypeOrd)
    r2 = pb.getField(2, pbSrc)
    r3 = pb.getField(3, pbDst)
    r4 = pb.getField(4, statusOrd)

  if r1.isErr() or r2.isErr() or r3.isErr() or r4.isErr():
    return none(RelayMessage)

  if r2.get() and
     (pbSrc.getField(1, src.peerId).isErr() or
      pbSrc.getRepeatedField(2, src.addrs).isErr()):
    return none(RelayMessage)

  if r3.get() and
     (pbDst.getField(1, dst.peerId).isErr() or
      pbDst.getRepeatedField(2, dst.addrs).isErr()):
    return none(RelayMessage)

  if r1.get(): rMsg.msgType = some(RelayType(msgTypeOrd))
  if r2.get(): rMsg.srcPeer = some(src)
  if r3.get(): rMsg.dstPeer = some(dst)
  if r4.get(): rMsg.status = some(RelayStatus(statusOrd))
  some(rMsg)

proc sendStatus*(conn: Connection, code: RelayStatus) {.async, gcsafe.} =
  trace "send status", status = $code & "(" & $ord(code) & ")"
  let
    msg = RelayMessage(
      msgType: some(RelayType.Status),
      status: some(code))
    pb = encodeMsg(msg)

  await conn.writeLp(pb.buffer)

proc handleHopStream(r: Relay, conn: Connection, msg: RelayMessage) {.async, gcsafe.} =
  r.streamCount.inc()
  defer:
    r.streamCount.dec()

  if r.streamCount > r.maxCircuit:
    trace "refusing connection; too many active circuit"
    await sendStatus(conn, RelayStatus.HopCantSpeakRelay)
    return

  proc checkMsg(): Result[RelayMessage, RelayStatus] =
    if not r.canHop:
      return err(RelayStatus.HopCantSpeakRelay)
    if msg.srcPeer.isNone:
      return err(RelayStatus.HopSrcMultiaddrInvalid)
    let src = msg.srcPeer.get()
    if src.peerId != conn.peerId:
      return err(RelayStatus.HopSrcMultiaddrInvalid)
    if msg.dstPeer.isNone:
      return err(RelayStatus.HopDstMultiaddrInvalid)
    let dst = msg.dstPeer.get()
    if dst.peerId == r.switch.peerInfo.peerId:
      return err(RelayStatus.HopCantRelayToSelf)
    if not r.switch.isConnected(dst.peerId):
      trace "relay not connected to dst", dst
      return err(RelayStatus.HopNoConnToDst)
    ok(msg)

  let check = checkMsg()
  if check.isErr:
    await sendStatus(conn, check.error())
    return
  let
    src = msg.srcPeer.get()
    dst = msg.dstPeer.get()

  # TODO: if r.acl # access control list
  #       and not r.acl.AllowHop(src.peerId, dst.peerId)
  #         sendStatus(conn, RelayStatus.HopCantSpeakRelay)

  r.hopCount.inc(src.peerId)
  r.hopCount.inc(dst.peerId)
  defer:
    r.hopCount.inc(src.peerId, -1)
    r.hopCount.inc(dst.peerId, -1)

  if r.hopCount[src.peerId] > r.maxCircuitPerPeer:
    trace "refusing connection; too many connection from src", src, dst
    await sendStatus(conn, RelayStatus.HopCantSpeakRelay)
    return

  if r.hopCount[dst.peerId] > r.maxCircuitPerPeer:
    trace "refusing connection; too many connection to dst", src, dst
    await sendStatus(conn, RelayStatus.HopCantSpeakRelay)
    return

  let connDst = try:
    await r.switch.dial(dst.peerId, @[RelayCodec])
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error opening relay stream", dst, exc=exc.msg
    await sendStatus(conn, RelayStatus.HopCantDialDst)
    return
  defer:
    await connDst.close()

  let msgToSend = RelayMessage(
    msgType: some(RelayType.Stop),
    srcPeer: some(src),
    dstPeer: some(dst),
    status: none(RelayStatus))

  let msgRcvFromDstOpt = try:
    await connDst.writeLp(encodeMsg(msgToSend).buffer)
    decodeMsg(await connDst.readLp(r.msgSize))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing stop handshake or reading stop response", exc=exc.msg
    await sendStatus(conn, RelayStatus.HopCantOpenDstStream)
    return

  if msgRcvFromDstOpt.isNone:
    trace "error reading stop response", msg = msgRcvFromDstOpt
    await sendStatus(conn, RelayStatus.HopCantOpenDstStream)
    return

  let msgRcvFromDst = msgRcvFromDstOpt.get()
  if msgRcvFromDst.msgType.isNone or msgRcvFromDst.msgType.get() != RelayType.Status:
    trace "unexcepted relay stop response", msgType = msgRcvFromDst.msgType
    await sendStatus(conn, RelayStatus.HopCantOpenDstStream)
    return

  if msgRcvFromDst.status.isNone or msgRcvFromDst.status.get() != RelayStatus.Success:
    trace "relay stop failure", status=msgRcvFromDst.status
    await sendStatus(conn, RelayStatus.HopCantOpenDstStream)
    return

  await sendStatus(conn, RelayStatus.Success)

  trace "relaying connection", src, dst

  proc bridge(conn: Connection, connDst: Connection) {.async.} =
    const bufferSize = 4096
    var
      bufSrcToDst: array[bufferSize, byte]
      bufDstToSrc: array[bufferSize, byte]
      futSrc = conn.readOnce(addr bufSrcToDst[0], bufSrcToDst.high + 1)
      futDst = connDst.readOnce(addr bufDstToSrc[0], bufDstToSrc.high + 1)
      bytesSendFromSrcToDst = 0
      bytesSendFromDstToSrc = 0
      bufRead: int

    while not conn.closed() and not connDst.closed():
      try:
        await futSrc or futDst
        if futSrc.finished():
          bufRead = await futSrc
          bytesSendFromSrcToDst.inc(bufRead)
          await connDst.write(@bufSrcToDst[0..<bufRead])
          zeroMem(addr(bufSrcToDst), bufSrcToDst.high + 1)
          futSrc = conn.readOnce(addr bufSrcToDst[0], bufSrcToDst.high + 1)
        if futDst.finished():
          bufRead = await futDst
          bytesSendFromDstToSrc += bufRead
          await conn.write(bufDstToSrc[0..<bufRead])
          zeroMem(addr(bufDstToSrc), bufDstToSrc.high + 1)
          futDst = connDst.readOnce(addr bufDstToSrc[0], bufDstToSrc.high + 1)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        if conn.closed() or conn.atEof():
          trace "relay src closed connection", src
        if connDst.closed() or connDst.atEof():
          trace "relay dst closed connection", dst
        trace "relay error", exc=exc.msg
        break

    trace "end relaying", bytesSendFromSrcToDst, bytesSendFromDstToSrc

    await futSrc.cancelAndWait()
    await futDst.cancelAndWait()
  await bridge(conn, connDst)

proc handleStopStream(r: Relay, conn: Connection, msg: RelayMessage) {.async, gcsafe.} =
  if msg.srcPeer.isNone:
    await sendStatus(conn, RelayStatus.StopSrcMultiaddrInvalid)
    return
  let src = msg.srcPeer.get()

  if msg.dstPeer.isNone:
    await sendStatus(conn, RelayStatus.StopDstMultiaddrInvalid)
    return

  let dst = msg.dstPeer.get()
  if dst.peerId != r.switch.peerInfo.peerId:
    await sendStatus(conn, RelayStatus.StopDstMultiaddrInvalid)
    return

  trace "get a relay connection", src, conn

  if r.addConn == nil:
    await sendStatus(conn, RelayStatus.StopRelayRefused)
    await conn.close()
    return
  await sendStatus(conn, RelayStatus.Success)
  # This sound redundant but the callback could, in theory, be set to nil during
  # sendStatus(Success) so it's safer to double check
  if r.addConn != nil: await r.addConn(conn)
  else: await conn.close()

proc handleCanHop(r: Relay, conn: Connection, msg: RelayMessage) {.async, gcsafe.} =
  await sendStatus(conn,
    if r.canHop:
      RelayStatus.Success
    else:
      RelayStatus.HopCantSpeakRelay
  )

proc new*(T: typedesc[Relay], switch: Switch, canHop: bool): T =
  let relay = T(switch: switch, canHop: canHop)
  relay.init()
  relay

method init*(r: Relay) =
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = decodeMsg(await conn.readLp(r.msgSize))

      if msgOpt.isNone:
        await sendStatus(conn, RelayStatus.MalformedMessage)
        return
      else:
        trace "relay handle stream", msg = msgOpt.get()
      let msg = msgOpt.get()

      case msg.msgType.get:
        of RelayType.Hop: await r.handleHopStream(conn, msg)
        of RelayType.Stop: await r.handleStopStream(conn, msg)
        of RelayType.CanHop: await r.handleCanHop(conn, msg)
        else:
          trace "Unexpected relay handshake", msgType=msg.msgType
          await sendStatus(conn, RelayStatus.MalformedMessage)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in relay handler", exc = exc.msg, conn
    finally:
      trace "exiting relay handler", conn
      await conn.close()

  r.handler = handleStream
  r.codecs = @[RelayCodec]

  r.maxCircuit = MaxCircuit
  r.maxCircuitPerPeer = MaxCircuitPerPeer
  r.msgSize = MsgSize

proc dialPeer(
    r: Relay,
    conn: Connection,
    dstPeerId: PeerId,
    dstAddrs: seq[MultiAddress]): Future[Connection] {.async.} =
  var
    msg = RelayMessage(
      msgType: some(RelayType.Hop),
      srcPeer: some(RelayPeer(peerId: r.switch.peerInfo.peerId, addrs: r.switch.peerInfo.addrs)),
      dstPeer: some(RelayPeer(peerId: dstPeerId, addrs: dstAddrs)),
      status: none(RelayStatus))
    pb = encodeMsg(msg)

  trace "Dial peer", msgSend=msg

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing hop request", exc=exc.msg
    raise exc

  let msgRcvFromRelayOpt = try:
    decodeMsg(await conn.readLp(r.msgSize))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error reading stop response", exc=exc.msg
    await sendStatus(conn, RelayStatus.HopCantOpenDstStream)
    raise exc

  if msgRcvFromRelayOpt.isNone:
    trace "error reading stop response", msg = msgRcvFromRelayOpt
    await sendStatus(conn, RelayStatus.HopCantOpenDstStream)
    raise newException(RelayError, "Hop can't open destination stream")

  let msgRcvFromRelay = msgRcvFromRelayOpt.get()
  if msgRcvFromRelay.msgType.isNone or msgRcvFromRelay.msgType.get() != RelayType.Status:
    trace "unexcepted relay stop response", msgType = msgRcvFromRelay.msgType
    await sendStatus(conn, RelayStatus.HopCantOpenDstStream)
    raise newException(RelayError, "Hop can't open destination stream")

  if msgRcvFromRelay.status.isNone or msgRcvFromRelay.status.get() != RelayStatus.Success:
    trace "relay stop failure", status=msgRcvFromRelay.status
    await sendStatus(conn, RelayStatus.HopCantOpenDstStream)
    raise newException(RelayError, "Hop can't open destination stream")
  result = conn

#
# Relay Transport
#

type
  RelayTransport* = ref object of Transport
    relay*: Relay
    queue: AsyncQueue[Connection]
    relayRunning: bool

method start*(self: RelayTransport, ma: seq[MultiAddress]) {.async.} =
  if self.relayRunning:
    trace "Relay transport already running"
    return
  await procCall Transport(self).start(ma)
  self.relayRunning = true
  self.relay.addConn = proc(conn: Connection) {.async, gcsafe, raises: [Defect].} =
    await self.queue.addLast(conn)
    await conn.join()
  trace "Starting Relay transport"

method stop*(self: RelayTransport) {.async, gcsafe.} =
  self.running = false
  self.relayRunning = false
  self.relay.addConn = nil
  while not self.queue.empty():
    await self.queue.popFirstNoWait().close()

method accept*(self: RelayTransport): Future[Connection] {.async, gcsafe.} =
  result = await self.queue.popFirst()

proc dial*(self: RelayTransport, ma: MultiAddress): Future[Connection] {.async, gcsafe.} =
  let
    sma = toSeq(ma.items())
    relayAddrs = sma[0..sma.len-4].mapIt(it.tryGet()).foldl(a & b)
  var
    relayPeerId: PeerId
    dstPeerId: PeerId
  if not relayPeerId.init(($(sma[^3].get())).split('/')[2]):
    raise newException(RelayError, "Relay doesn't exist")
  if not dstPeerId.init(($(sma[^1].get())).split('/')[2]):
    raise newException(RelayError, "Destination doesn't exist")
  trace "Dial", relayPeerId, relayAddrs, dstPeerId

  let conn = await self.relay.switch.dial(relayPeerId, @[ relayAddrs ], RelayCodec)
  result = await self.relay.dialPeer(conn, dstPeerId, @[])

method dial*(
  self: RelayTransport,
  hostname: string,
  address: MultiAddress): Future[Connection] {.async, gcsafe.} =
  result = await self.dial(address)

method handles*(self: RelayTransport, ma: MultiAddress): bool {.gcsafe} =
  if ma.protocols.isOk:
    let sma = toSeq(ma.items())
    if sma.len >= 3:
      result = CircuitRelay.match(sma[^2].get()) and
               P2PPattern.match(sma[^1].get())
  trace "Handles return", ma, result

proc new*(T: typedesc[RelayTransport], relay: Relay, upgrader: Upgrade): T =
  result = T(relay: relay, upgrader: upgrader)
  result.running = true
  result.queue = newAsyncQueue[Connection](0)

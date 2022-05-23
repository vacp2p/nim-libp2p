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

import ../../peerinfo,
       ../../switch,
       ../../multiaddress,
       ../../stream/connection,
       ../../protocols/protocol,
       ../../transports/transport,
       ../../utility,
       ../../errors
import ./messages

const
  RelayCodec* = "/libp2p/circuit/relay/0.1.0"
  MsgSize* = 4096
  MaxCircuit* = 1024
  MaxCircuitPerPeer* = 64

logScope:
  topics = "libp2p relay"

type
  RelayError* = object of LPError

  AddConn* = proc(conn: Connection): Future[void] {.gcsafe, raises: [Defect].}

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

proc sendStatus*(conn: Connection, code: StatusV1) {.async, gcsafe.} =
  trace "send status", status = $code & "(" & $ord(code) & ")"
  let
    msg = RelayMessage(
      msgType: some(RelayType.Status),
      status: some(code))
    pb = encode(msg)

  await conn.writeLp(pb.buffer)

proc handleHopStream(r: Relay, conn: Connection, msg: RelayMessage) {.async, gcsafe.} =
  r.streamCount.inc()
  defer:
    r.streamCount.dec()

  if r.streamCount > r.maxCircuit:
    trace "refusing connection; too many active circuit"
    await sendStatus(conn, StatusV1.HopCantSpeakRelay)
    return

  proc checkMsg(): Result[RelayMessage, StatusV1] =
    if not r.canHop:
      return err(StatusV1.HopCantSpeakRelay)
    if msg.srcPeer.isNone:
      return err(StatusV1.HopSrcMultiaddrInvalid)
    let src = msg.srcPeer.get()
    if src.peerId != conn.peerId:
      return err(StatusV1.HopSrcMultiaddrInvalid)
    if msg.dstPeer.isNone:
      return err(StatusV1.HopDstMultiaddrInvalid)
    let dst = msg.dstPeer.get()
    if dst.peerId == r.switch.peerInfo.peerId:
      return err(StatusV1.HopCantRelayToSelf)
    if not r.switch.isConnected(dst.peerId):
      trace "relay not connected to dst", dst
      return err(StatusV1.HopNoConnToDst)
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
  #         sendStatus(conn, StatusV1.HopCantSpeakRelay)

  r.hopCount.inc(src.peerId)
  r.hopCount.inc(dst.peerId)
  defer:
    r.hopCount.inc(src.peerId, -1)
    r.hopCount.inc(dst.peerId, -1)

  if r.hopCount[src.peerId] > r.maxCircuitPerPeer:
    trace "refusing connection; too many connection from src", src, dst
    await sendStatus(conn, StatusV1.HopCantSpeakRelay)
    return

  if r.hopCount[dst.peerId] > r.maxCircuitPerPeer:
    trace "refusing connection; too many connection to dst", src, dst
    await sendStatus(conn, StatusV1.HopCantSpeakRelay)
    return

  let connDst = try:
    await r.switch.dial(dst.peerId, @[RelayCodec])
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error opening relay stream", dst, exc=exc.msg
    await sendStatus(conn, StatusV1.HopCantDialDst)
    return
  defer:
    await connDst.close()

  let msgToSend = RelayMessage(
    msgType: some(RelayType.Stop),
    srcPeer: some(src),
    dstPeer: some(dst))

  let msgRcvFromDstOpt = try:
    await connDst.writeLp(encode(msgToSend).buffer)
    RelayMessage.decode(await connDst.readLp(r.msgSize))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing stop handshake or reading stop response", exc=exc.msg
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    return

  if msgRcvFromDstOpt.isNone:
    trace "error reading stop response", msg = msgRcvFromDstOpt
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    return

  let msgRcvFromDst = msgRcvFromDstOpt.get()
  if msgRcvFromDst.msgType.isNone or msgRcvFromDst.msgType.get() != RelayType.Status:
    trace "unexcepted relay stop response", msgType = msgRcvFromDst.msgType
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    return

  if msgRcvFromDst.status.isNone or msgRcvFromDst.status.get() != StatusV1.Success:
    trace "relay stop failure", status=msgRcvFromDst.status
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    return

  await sendStatus(conn, StatusV1.Success)

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
    await sendStatus(conn, StatusV1.StopSrcMultiaddrInvalid)
    return
  let src = msg.srcPeer.get()

  if msg.dstPeer.isNone:
    await sendStatus(conn, StatusV1.StopDstMultiaddrInvalid)
    return

  let dst = msg.dstPeer.get()
  if dst.peerId != r.switch.peerInfo.peerId:
    await sendStatus(conn, StatusV1.StopDstMultiaddrInvalid)
    return

  trace "get a relay connection", src, conn

  if r.addConn == nil:
    await sendStatus(conn, StatusV1.StopRelayRefused)
    await conn.close()
    return
  await sendStatus(conn, StatusV1.Success)
  # This sound redundant but the callback could, in theory, be set to nil during
  # sendStatus(Success) so it's safer to double check
  if r.addConn != nil: await r.addConn(conn)
  else: await conn.close()

proc handleCanHop(r: Relay, conn: Connection, msg: RelayMessage) {.async, gcsafe.} =
  await sendStatus(conn,
    if r.canHop:
      StatusV1.Success
    else:
      StatusV1.HopCantSpeakRelay
  )

proc new*(T: typedesc[Relay], switch: Switch, canHop: bool): T =
  let relay = T(switch: switch, canHop: canHop)
  relay.init()
  relay

method init*(r: Relay) =
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = RelayMessage.decode(await conn.readLp(r.msgSize))

      if msgOpt.isNone:
        await sendStatus(conn, StatusV1.MalformedMessage)
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
          await sendStatus(conn, StatusV1.MalformedMessage)
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
      dstPeer: some(RelayPeer(peerId: dstPeerId, addrs: dstAddrs)))
    pb = encode(msg)

  trace "Dial peer", msgSend=msg

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing hop request", exc=exc.msg
    raise exc

  let msgRcvFromRelayOpt = try:
    RelayMessage.decode(await conn.readLp(r.msgSize))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error reading stop response", exc=exc.msg
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    raise exc

  if msgRcvFromRelayOpt.isNone:
    trace "error reading stop response", msg = msgRcvFromRelayOpt
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    raise newException(RelayError, "Hop can't open destination stream")

  let msgRcvFromRelay = msgRcvFromRelayOpt.get()
  if msgRcvFromRelay.msgType.isNone or msgRcvFromRelay.msgType.get() != RelayType.Status:
    trace "unexcepted relay stop response", msgType = msgRcvFromRelay.msgType
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
    raise newException(RelayError, "Hop can't open destination stream")

  if msgRcvFromRelay.status.isNone or msgRcvFromRelay.status.get() != StatusV1.Success:
    trace "relay stop failure", status=msgRcvFromRelay.status
    await sendStatus(conn, StatusV1.HopCantOpenDstStream)
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

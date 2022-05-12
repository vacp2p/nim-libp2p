## Nim-LibP2P
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import strutils, sequtils, tables
import chronos, chronicles

import ./messages,
       ../../peerinfo,
       ../../switch,
       ../../multiaddress,
       ../../multicodec,
       ../../stream/connection,
       ../../protocols/protocol,
       ../../transports/transport,
       ../../errors,
       ../../signed_envelope

# TODO:
# * Eventually replace std/times by chronos/timer. Currently chronos/timer
#   doesn't offer the possibility to get a datetime in UNIX UTC
# * Eventually add an access control list in the handleReserve and
#   handleConnect of the Relay
# * When the circuit relay v1 will be merged with unstable:
#   + add a backward compatibility on the RelayV2Transport
#   + remove the two Pattern
# * Better reservation management ie find a way to re-reserve when the end is
#   nigh
import std/times
export chronicles

const
  RelayV2HopCodec = "/libp2p/circuit/relay/0.2.0/hop"
  RelayV2StopCodec = "/libp2p/circuit/relay/0.2.0/stop"
  MsgSize = 4096
  DefaultReservationTTL = initDuration(hours = 1)
  DefaultLimitDuration = 120
  DefaultLimitData = 1 shl 17
  DefaultHeartbeatSleepTime = 1
  MaxCircuit = 1024
  MaxCircuitPerPeer = 64

logScope:
  topics = "libp2p relayv2"

type
  RelayV2Error* = object of LPError
  ReservationError* = object of RelayV2Error
  RelayV2DialError* = object of RelayV2Error
  SendStopError = object of RelayV2Error

  RelayV2* = ref object of LPProtocol
    switch: Switch
    peerId: PeerID
    rsvp: Table[PeerId, DateTime]

    streamCount: int
    peerCount: CountTable[PeerId]

    heartbeatFut: Future[void]

    reservationTTL*: times.Duration
    limit*: Limit
    heartbeatSleepTime*: uint32
    maxCircuit*: int
    maxCircuitPerPeer*: int
    msgSize*: int

# Relay Connection

type
  RelayConnection = ref object of Connection
    conn*: Connection
    limitDuration: uint32
    limitData: uint64
    dataSent: uint64

method readOnce*(
  self: RelayConnection,
  pbytes: pointer,
  nbytes: int):
  Future[int] {.async.} =
  return await self.conn.readOnce(pbytes, nbytes)

method write*(self: RelayConnection, msg: seq[byte]): Future[void] {.async.} =
  self.dataSent.inc(msg.len)
  if self.limitData != 0 and self.dataSent > self.limitData:
    await self.close()
    return
  await self.conn.write(msg)

method closeImpl*(self: RelayConnection): Future[void] {.async.} =
  await self.conn.closeImpl()
  await procCall Connection(self).closeImpl()

method isCircuitRelay*(self: RelayConnection): bool = true

proc new*(
  T: typedesc[RelayConnection],
  conn: Connection,
  limitDuration: uint32,
  limitData: uint64): T =
  let rv = T(conn: conn, limitDuration: limitDuration, limitData: limitData)
  rv.initStream()
  if limitDuration > 0:
    asyncSpawn (proc () {.async.} =
      let sleep = sleepAsync(limitDuration.seconds())
      await sleep or conn.join()
      if sleep.finished(): await conn.close()
      else: sleep.cancel())()
  return rv

# Protocols

proc sendHopError*(conn: Connection, code: Status) {.async, gcsafe.} =
  trace "send hop status", status = $code & "(" & $ord(code) & ")"
  let
    msg = HopMessage(msgType: HopMessageType.Status, status: some(code))
    pb = encode(msg)
  await conn.writeLp(pb.buffer)

proc createReserveResponse(
    rv2: RelayV2,
    pid: PeerID,
    expire: DateTime): Result[HopMessage, CryptoError] =
  let
    expireUnix = expire.toTime.toUnix.uint64
    v = Voucher(relayPeerId: rv2.switch.peerInfo.peerId,
                  reservingPeerId: pid,
                  expiration: expireUnix)
    sv = ? SignedVoucher.init(rv2.switch.peerInfo.privateKey, v)
    ma = MultiAddress.init("/p2p/" & $rv2.switch.peerInfo.peerId).tryGet()
    rsrv = Reservation(expire: expireUnix,
                       addrs: rv2.switch.peerInfo.addrs.mapIt(it & ma),
                       svoucher: some(? sv.encode))
    msg = HopMessage(msgType: HopMessageType.Status,
                     reservation: some(rsrv),
                     limit: rv2.limit,
                     status: some(Ok))
  return ok(msg)

proc handleReserve(rv2: RelayV2, connSrc: Connection) {.async, gcsafe.} =
  if connSrc.isCircuitRelay():
    trace "reservation attempt over relay connection", pid = connSrc.peerId
    await sendHopError(connSrc, PermissionDenied)
    return

  let
    pid = connSrc.peerId
    expire = now().utc + rv2.reservationTTL
    msg = rv2.createReserveResponse(pid, expire)

  trace "reserving relay slot for", pid
  if msg.isErr():
    trace "error signing the voucher", error = error(msg), pid
    return
  rv2.rsvp[pid] = expire
  await connSrc.writeLp(encode(msg.get()).buffer)

proc handleConnect(rv2: Relayv2,
                   connSrc: Connection,
                   msg: HopMessage) {.async, gcsafe.} =
  rv2.streamCount.inc()
  defer: rv2.streamCount.dec()

  if rv2.streamCount > rv2.maxCircuit:
    trace "refusing connection; too many active circuit"
    await sendHopError(connSrc, ResourceLimitExceeded)
    return

  if connSrc.isCircuitRelay():
    trace "connection attempt over relay connection"
    await sendHopError(connSrc, PermissionDenied)
    return

  if msg.peer.isNone():
    await sendHopError(connSrc, MalformedMessage)
    return

  let
    src = connSrc.peerId
    dst = msg.peer.get().peerId

  if dst notin rv2.rsvp:
    trace "refusing connection, no reservation", src, dst
    await sendHopError(connSrc, NoReservation)
    return

  rv2.peerCount.inc(src)
  rv2.peerCount.inc(dst)
  defer:
    rv2.peerCount.inc(src, -1)
    rv2.peerCount.inc(dst, -1)

  if rv2.peerCount[src] > rv2.maxCircuitPerPeer or
     rv2.peerCount[dst] > rv2.maxCircuitPerPeer:
    trace "too many connections", src = rv2.peerCount[src],
                                  dst = rv2.peerCount[dst],
                                  max = rv2.maxCircuitPerPeer
    await sendHopError(connSrc, ResourceLimitExceeded)
    return

  let connDst = try:
    await rv2.switch.dial(dst, RelayV2StopCodec)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error opening relay stream", dst, exc=exc.msg
    await sendHopError(connSrc, ConnectionFailed)
    return
  defer:
    await connDst.close()

  proc sendStopMsg() {.async.} =
    let stopMsg = StopMessage(msgType: StopMessageType.Connect,
                            peer: some(Peer(peerId: src, addrs: @[])),
                            limit: rv2.limit)
    await connDst.writeLP(encode(stopMsg).buffer)
    let msg = StopMessage.decode(await connDst.readLp(rv2.msgSize)).get()
    if msg.msgType != StopMessageType.Status:
      raise newException(SendStopError, "Unexpected stop response, not a status message")
    if msg.status.get(UnexpectedMessage) != Ok:
      raise newException(SendStopError, "Relay stop failure")
    await connSrc.writeLp(encode(HopMessage(msgType: HopMessageType.Status,
                                          status: some(Ok))).buffer)
  try:
    await sendStopMsg()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error sending stop message", msg = exc.msg
    await sendHopError(connSrc, ConnectionFailed)
    return

  trace "relaying connection", src, dst

  proc bridge(connSrc: Connection, connDst: Connection) {.async.} =
    const bufferSize = 4096
    var
      bufSrcToDst: array[bufferSize, byte]
      bufDstToSrc: array[bufferSize, byte]
      futSrc = connSrc.readOnce(addr bufSrcToDst[0], bufSrcToDst.len)
      futDst = connDst.readOnce(addr bufDstToSrc[0], bufDstToSrc.len)
      bytesSendFromSrcToDst = 0
      bytesSendFromDstToSrc = 0
      bufRead: int

    while not connSrc.closed() and not connDst.closed():
      try:
        await futSrc or futDst
        if futSrc.finished():
          bufRead = await futSrc
          assert bufRead <= bufferSize
          bytesSendFromSrcToDst.inc(bufRead)
          await connDst.write(@bufSrcToDst[0..<bufRead])
          zeroMem(addr(bufSrcToDst), bufferSize)
          futSrc = connSrc.readOnce(addr bufSrcToDst[0], bufSrcToDst.len)
        if futDst.finished():
          bufRead = await futDst
          assert bufRead <= bufferSize
          bytesSendFromDstToSrc += bufRead
          await connSrc.write(bufDstToSrc[0..<bufRead])
          zeroMem(addr(bufDstToSrc), bufferSize)
          futDst = connDst.readOnce(addr bufDstToSrc[0], bufDstToSrc.len)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        if connSrc.closed() or connSrc.atEof():
          trace "relay src closed connection", src
        if connDst.closed() or connDst.atEof():
          trace "relay dst closed connection", dst
        trace "relay error", exc=exc.msg
        break

    trace "end relaying", bytesSendFromSrcToDst, bytesSendFromDstToSrc

    await futSrc.cancelAndWait()
    await futDst.cancelAndWait()
  await bridge(RelayConnection.new(connSrc, rv2.limit.duration, rv2.limit.data),
               RelayConnection.new(connDst, rv2.limit.duration, rv2.limit.data))

proc heartbeat(rv2: RelayV2) {.async.} =
  while true:
    let n = now().utc
    var rsvp = rv2.rsvp
    for k, v in rv2.rsvp.mpairs:
      if n > v:
        rsvp.del(k)
    rv2.rsvp = rsvp

    await sleepAsync(chronos.seconds(rv2.heartbeatSleepTime))


proc new*(T: typedesc[RelayV2], switch: Switch,
     reservationTTL: times.Duration = DefaultReservationTTL,
     limitDuration: uint32 = DefaultLimitDuration,
     limitData: uint64 = DefaultLimitData,
     heartbeatSleepTime: uint32 = DefaultHeartbeatSleepTime,
     maxCircuit: int = MaxCircuit,
     maxCircuitPerPeer: int = MaxCircuitPerPeer,
     msgSize: int = MsgSize): T =

  let rv2 = T(switch: switch,
    codecs: @[RelayV2HopCodec],
    reservationTTL: reservationTTL,
    limit: Limit(duration: limitDuration, data: limitData),
    heartbeatSleepTime: heartbeatSleepTime,
    maxCircuit: maxCircuit,
    maxCircuitPerPeer: maxCircuitPerPeer,
    msgSize: msgSize)

  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = HopMessage.decode(await conn.readLp(rv2.msgSize))

      if msgOpt.isNone():
        await sendHopError(conn, MalformedMessage)
        return
      trace "relayv2 handle stream", msg = msgOpt.get()
      let msg = msgOpt.get()

      case msg.msgType:
        of HopMessageType.Reserve: await rv2.handleReserve(conn)
        of HopMessageType.Connect: await rv2.handleConnect(conn, msg)
        else:
          trace "Unexpected relayv2 handshake", msgType=msg.msgType
          await sendHopError(conn, MalformedMessage)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "exception in relayv2 handler", exc = exc.msg, conn
    finally:
      trace "exiting relayv2 handler", conn
      await conn.close()

  rv2.handler = handleStream
  rv2

proc start*(rv2: RelayV2) {.async.} =
  if not rv2.heartbeatFut.isNil:
    warn "Starting relayv2 twice"
    return

  rv2.heartbeatFut = rv2.heartbeat()

proc stop*(rv2: RelayV2) {.async.} =
  if rv2.heartbeatFut.isNil:
    warn "Stopping relayv2 without starting it"
    return

  rv2.heartbeatFut.cancel()

# Client side

type
  Client* = ref object of LPProtocol
    switch: Switch
    queue: AsyncQueue[Connection]

proc sendStopError(conn: Connection, code: Status) {.async.} =
  trace "send stop status", status = $code & " (" & $ord(code) & ")"
  let msg = StopMessage(msgType: StopMessageType.Status, status: some(code))
  await conn.writeLp(encode(msg).buffer)

proc handleConnect(cl: Client, conn: Connection, msg: StopMessage) {.async.} =
  if msg.peer.isNone():
    await sendStopError(conn, MalformedMessage)
    return
  let
    # TODO: check the go version to see in which way this could fail
    # it's unclear in the spec
    src = msg.peer.get()
    limitDuration = msg.limit.duration
    limitData = msg.limit.data
    msg = StopMessage(
      msgType: StopMessageType.Status,
      status: some(Ok))
    pb = encode(msg)

  trace "incoming relay connection", src

  await conn.writeLp(pb.buffer)
  await cl.queue.addLast(RelayConnection.new(conn, limitDuration, limitData))
  await conn.join()

type
  Rsvp* = object
    expire*: uint64           # required, Unix expiration time (UTC)
    addrs*: seq[MultiAddress] # relay address for reserving peer
    voucher*: Option[Voucher] # optional, reservation voucher
    limitDuration*: uint32    # seconds
    limitData*: uint64        # bytes

proc reserve*(cl: Client, relayPI: PeerInfo): Future[Rsvp] {.async.} =
  let conn = await cl.switch.dial(relayPI.peerId, relayPI.addrs, RelayV2HopCodec)
  defer: await conn.close()
  let
    pb = encode(HopMessage(msgType: HopMessageType.Reserve))
    msg = try:
      await conn.writeLp(pb.buffer)
      HopMessage.decode(await conn.readLp(MsgSize)).get()
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "error writing or reading reservation message", exc=exc.msg
      raise newException(ReservationError, exc.msg)

  if msg.msgType != HopMessageType.Status:
    raise newException(ReservationError, "Unexpected relay response type")
  if msg.status.get(UnexpectedMessage) != Ok:
    raise newException(ReservationError, "Reservation failed")
  if msg.reservation.isNone():
    raise newException(ReservationError, "Missing reservation information")

  let reservation = msg.reservation.get()
  if now().utc > reservation.expire.int64.fromUnix.utc:
    raise newException(ReservationError, "Bad expiration date")
  result.expire = reservation.expire
  result.addrs = reservation.addrs

  if reservation.svoucher.isSome():
    let svoucher = SignedVoucher.decode(reservation.svoucher.get())
    if svoucher.isErr() or svoucher.get().data.relayPeerId != relayPI.peerId:
      raise newException(ReservationError, "Invalid voucher")
    result.voucher = some(svoucher.get().data)

  result.limitDuration = msg.limit.duration
  result.limitData = msg.limit.data

proc dialPeer(
    cl: Client,
    conn: RelayConnection,
    dstPeerId: PeerID,
    dstAddrs: seq[MultiAddress]): Future[Connection] {.async.} =
  let
    p = Peer(peerId: dstPeerId, addrs: dstAddrs)
    pb = encode(HopMessage(msgType: HopMessageType.Connect, peer: some(p)))

  trace "Dial peer", p

  let msgRcvFromRelay = try:
    await conn.writeLp(pb.buffer)
    HopMessage.decode(await conn.readLp(MsgSize)).get()
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error reading stop response", exc=exc.msg
    raise newException(RelayV2DialError, exc.msg)

  if msgRcvFromRelay.msgType != HopMessageType.Status:
    raise newException(RelayV2DialError, "Unexpected stop response")
  if msgRcvFromRelay.status.get(UnexpectedMessage) != Ok:
    raise newException(RelayV2DialError, "Relay stop failure")
  conn.limitDuration = msgRcvFromRelay.limit.duration
  conn.limitData = msgRcvFromRelay.limit.data
  return conn

proc new*(T: typedesc[Client], switch: Switch): T =
  let cl = T(switch: switch)
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = StopMessage.decode(await conn.readLp(MsgSize))

      if msgOpt.isNone():
        await sendHopError(conn, MalformedMessage)
        return
      trace "client handle stream", msg = msgOpt.get()
      let msg = msgOpt.get()

      if msg.msgType == StopMessageType.Connect:
        await cl.handleConnect(conn, msg)
      else:
        trace "Unexpected client / relayv2 handshake", msgType=msg.msgType
        await sendStopError(conn, MalformedMessage)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in client handler", exc = exc.msg, conn
    finally:
      trace "exiting client handler", conn
      await conn.close()

  cl.queue = newAsyncQueue[Connection](0)
  cl.handler = handleStream
  cl.codecs = @[RelayV2StopCodec]
  cl

# Transport

type
  RelayV2Transport* = ref object of Transport
    client*: Client

method start*(self: RelayV2Transport, ma: seq[MultiAddress]) {.async.} =
  if self.running:
    trace "Relay transport already running"
    return

  await procCall Transport(self).start(ma)
  trace "Starting Relay transport"

method stop*(self: RelayV2Transport) {.async, gcsafe.} =
  self.running = false
  while not self.client.queue.empty():
    await self.client.queue.popFirstNoWait().close()

method accept*(self: RelayV2Transport): Future[Connection] {.async, gcsafe.} =
  result = await self.client.queue.popFirst()

proc dial*(self: RelayV2Transport, ma: MultiAddress): Future[Connection] {.async, gcsafe.} =
  let
    sma = toSeq(ma.items())
    relayAddrs = sma[0..sma.len-4].mapIt(it.tryGet()).foldl(a & b)
  var
    relayPeerId: PeerId
    dstPeerId: PeerId
  if not relayPeerId.init(($(sma[^3].get())).split('/')[2]):
    # raise smthg
    return
  if not dstPeerId.init(($(sma[^1].get())).split('/')[2]):
    # raise smthg
    return
  trace "Dial", relayPeerId, relayAddrs, dstPeerId

  let conn = await self.client.switch.dial(relayPeerId, @[ relayAddrs ], RelayV2HopCodec)
  let rc = RelayConnection.new(conn, 0, 0)
  result = await self.client.dialPeer(rc, dstPeerId, @[])

method dial*(
  self: RelayV2Transport,
  hostname: string,
  address: MultiAddress): Future[Connection] {.async, gcsafe.} =
  result = await self.dial(address)

const
  P2PPattern = mapEq("p2p")
  CircuitRelay = mapEq("p2p-circuit")

method handles*(self: RelayV2Transport, ma: MultiAddress): bool {.gcsafe} =
  if ma.protocols.isOk():
    let sma = toSeq(ma.items())
    if sma.len >= 3:
      result = CircuitRelay.match(sma[^2].get()) and
               P2PPattern.match(sma[^1].get())
  trace "Handles return", ma, result

proc new*(T: typedesc[RelayV2Transport], cl: Client, upgrader: Upgrade): T =
  T(client: cl, upgrader: upgrader)

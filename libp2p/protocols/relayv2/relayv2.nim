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

import ./voucher,
       ../../peerinfo,
       ../../switch,
       ../../multiaddress,
       ../../multicodec,
       ../../stream/connection,
       ../../protocols/protocol,
       ../../transports/transport,
       ../../errors,
       ../../signed_envelope

import std/times # Eventually replace it by chronos/timer

const
  RelayV2HopCodec* = "/libp2p/circuit/relay/0.2.0/hop"
  RelayV2StopCodec* = "/libp2p/circuit/relay/0.2.0/stop"
  MsgSize* = 4096
  DefaultReservationTTL* = initDuration(hours = 1)
  DefaultLimitDuration* = 120
  DefaultLimitData* = 1 shl 17
  DefaultHeartbeatSleepTime = 1

logScope:
  topics = "libp2p relayv2"

type
  RelayV2Error* = object of LPError
  RelayV2Status* = enum
    Ok = 100
    ReservationRefused = 200
    ResourceLimitExceeded = 201
    PermissionDenied = 202
    ConnectionFailed = 203
    NoReservation = 204
    MalformedMessage = 400
    UnexpectedMessage = 401
  HopMessageType* {.pure.} = enum
    Reserve = 0
    Connect = 1
    Status = 2
  HopMessage* = object
    msgType*: HopMessageType
    peer*: Option[RelayV2Peer]
    reservation*: Option[Reservation]
    limit*: Option[RelayV2Limit]
    status*: Option[RelayV2Status]

  StopMessageType* {.pure.} = enum
    Connect = 0
    Status = 1
  StopMessage* = object
    msgType*: StopMessageType
    peer*: Option[RelayV2Peer]
    limit*: Option[RelayV2Limit]
    status*: Option[RelayV2Status]

  RelayV2Peer* = object
    peerId*: PeerID
    addrs*: seq[MultiAddress]
  Reservation* = object
    expire: uint64 # required, Unix expiration time (UTC)
    addrs: seq[MultiAddress] # relay address for reserving peer
    svoucher: Option[seq[byte]] # optional, reservation voucher
  RelayV2Limit* = object
    duration: uint32 # seconds
    data: uint64 # bytes

  RelayV2* = ref object of LPProtocol
    switch: Switch
    peerId: PeerID
    rsvp: Table[PeerId, DateTime] # TODO: eventually replace by chronos/timer
    hopCount: CountTable[PeerID]

    reservationTTL*: times.Duration # TODO: eventually replace by chronos/timer
    limit*: RelayV2Limit
    heartbeatSleepTime*: uint32 # seconds
    msgSize*: int

# Hop Protocol

proc encodeHopMessage*(msg: HopMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.msgType.ord.uint)
  if msg.peer.isSome():
    var ppb = initProtoBuffer()
    ppb.write(1, msg.peer.get().peerId)
    for ma in msg.peer.get().addrs:
      ppb.write(2, ma.data.buffer)
    ppb.finish()
    pb.write(2, ppb.buffer)
  if msg.reservation.isSome():
    let rsrv = msg.reservation.get()
    var rpb = initProtoBuffer()
    rpb.write(1, rsrv.expire)
    for ma in rsrv.addrs:
      rpb.write(2, ma.data.buffer)
    if rsrv.svoucher.isSome():
      rpb.write(3, rsrv.svoucher.get())
    rpb.finish()
    pb.write(3, rpb.buffer)
  if msg.limit.isSome():
    let limit = msg.limit.get()
    var lpb = initProtoBuffer()
    lpb.write(1, limit.duration)
    lpb.write(2, limit.data)
    lpb.finish()
    pb.write(4, lpb.buffer)
  if msg.status.isSome():
    pb.write(5, msg.status.get().ord.uint)

  pb.finish()
  pb

proc decodeHopMessage(buf: seq[byte]): Option[HopMessage] =
  var
    msg: HopMessage
    msgTypeOrd: uint32
    pbPeer: ProtoBuffer
    pbReservation: ProtoBuffer
    pbLimit: ProtoBuffer
    statusOrd: uint32
    peer: RelayV2Peer
    reservation: Reservation
    limit: RelayV2Limit
    res: bool

  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, msgTypeOrd)
    r2 = pb.getField(2, pbPeer)
    r3 = pb.getField(3, pbReservation)
    r4 = pb.getField(4, pbLimit)
    r5 = pb.getField(5, statusOrd)

  if r1.isErr() or r2.isErr() or r3.isErr() or r4.isErr() or r5.isErr():
    return none(HopMessage)

  if r2.get() and
     (pbPeer.getRequiredField(1, peer.peerId).isErr() or
      pbPeer.getRepeatedField(2, peer.addrs).isErr()):
    return none(HopMessage)

  if r3.get():
    var svoucher: seq[byte]
    let rSVoucher = pbReservation.getField(3, svoucher)
    if pbReservation.getRequiredField(1, reservation.expire).isErr() or
       pbReservation.getRepeatedField(2, reservation.addrs).isErr() or
       rSVoucher.isErr():
      return none(HopMessage)
    if rSVoucher.get(): reservation.svoucher = some(svoucher)

  if r4.get() and
     (pbLimit.getField(1, limit.duration).isErr() or
      pbLimit.getField(1, limit.data).isErr()):
    return none(HopMessage)

  msg.msgType = HopMessageType(msgTypeOrd)
  if r2.get(): msg.peer = some(peer)
  if r3.get(): msg.reservation = some(reservation)
  if r4.get(): msg.limit = some(limit)
  if r5.get(): msg.status = some(RelayV2Status(statusOrd))
  some(msg)

proc handleHopError*(conn: Connection, code: RelayV2Status) {.async, gcsafe.} =
  trace "send hop status", status = $code & "(" & $ord(code) & ")"
  let
    msg = HopMessage(msgType: HopMessageType.Status, status: some(code))
    pb = encodeHopMessage(msg)

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing error msg", exc=exc.msg, code

# Stop Message

proc encodeStopMessage(msg: StopMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.msgType.ord.uint)
  if msg.peer.isSome():
    var ppb = initProtoBuffer()
    ppb.write(1, msg.peer.get().peerId)
    for ma in msg.peer.get().addrs:
      ppb.write(2, ma.data.buffer)
    ppb.finish()
    pb.write(2, ppb.buffer)
  if msg.limit.isSome():
    var lpb = initProtoBuffer()
    let limit = msg.limit.get()
    lpb.write(1, limit.duration)
    lpb.write(2, limit.data)
    lpb.finish()
    pb.write(3, lpb.buffer)
  if msg.status.isSome():
    pb.write(4, msg.status.get().ord.uint)

  pb.finish()
  pb

proc decodeStopMessage(buf: seq[byte]): Option[StopMessage] =
  var
    msg: StopMessage
    msgTypeOrd: uint32
    pbPeer: ProtoBuffer
    pbLimit: ProtoBuffer
    statusOrd: uint32
    peer: RelayV2Peer
    limit: RelayV2Limit
    rVoucher: ProtoResult[bool]
    res: bool

  let
    pb = initProtoBuffer(buf)
    r1 = pb.getRequiredField(1, msgTypeOrd)
    r2 = pb.getField(2, pbPeer)
    r3 = pb.getField(3, pbLimit)
    r4 = pb.getField(4, statusOrd)

  if r1.isErr() or r2.isErr() or r3.isErr() or r4.isErr():
    return none(StopMessage)

  if r2.get() and
     (pbPeer.getRequiredField(1, peer.peerId).isErr() or
      pbPeer.getRepeatedField(2, peer.addrs).isErr()):
    return none(StopMessage)

  if r3.get() and
     (pbLimit.getField(1, limit.duration).isErr() or
      pbLimit.getField(1, limit.data).isErr()):
    return none(StopMessage)

  msg.msgType = StopMessageType(msgTypeOrd)
  if r2.get(): msg.peer = some(peer)
  if r3.get(): msg.limit = some(limit)
  if r4.get(): msg.status = some(RelayV2Status(statusOrd))
  some(msg)

# Protocols

proc createHopMessage(
    rv2: RelayV2,
    pid: PeerID,
    expire: DateTime): Result[HopMessage, CryptoError] =
  var msg: HopMessage
  let expireUnix = expire.toTime.toUnix.uint64
  let v = Voucher(relayPeerId: rv2.switch.peerInfo.peerId,
                  reservingPeerId: pid,
                  expiration: expireUnix)
  let sv = ? SignedVoucher.init(rv2.switch.peerInfo.privateKey, v)
  msg.reservation = some(Reservation(expire: expireUnix,
                         addrs: rv2.switch.peerInfo.addrs,
                         svoucher: some(? sv.encode)))
  msg.limit = some(rv2.limit)
  msg.msgType = HopMessageType.Status
  msg.status = some(Ok)
  return ok(msg)

proc handleReserve(rv2: RelayV2, conn: Connection) {.async, gcsafe.} =
  let
    pid = conn.peerId
    addrs = conn.observedAddr
    testAddrs = addrs.contains(multiCodec("p2p-circuit"))

  if testAddrs.isErr() or testAddrs.get():
    trace "reservation attempt over relay connection", pid
    await handleHopError(conn, RelayV2Status.PermissionDenied)
    return

  # TODO: Access Control List check, eventually

  let expire = now().utc + rv2.reservationTTL
  rv2.rsvp[pid] = expire

  trace "reserving relay slot for", pid

  let msg = rv2.createHopMessage(pid, expire)
  if msg.isErr():
    trace "error signing the voucher", error = error(msg), pid, addrs
    # conn.reset()
    return
  let pb = encodeHopMessage(msg.get())

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing reservation response", exc=exc.msg, retractedPid = pid
    # conn.reset()

proc handleConnect(rv2: Relayv2, conn: Connection, msg: HopMessage) {.async, gcsafe.} =
  let
    src = conn.peerId
    addrs = conn.observedAddr
    testAddrs = addrs.contains(multiCodec("p2p-circuit"))

  if msg.peer.isNone():
    await handleHopError(conn, RelayV2Status.MalformedMessage)
    return

  let dst = msg.peer.get()

  if testAddrs.isErr() or testAddrs.get():
    trace "connection attempt over relay connection", src = conn.peerId
    await handleHopError(conn, RelayV2Status.PermissionDenied)
    return

  # TODO: Access Control List check, eventually

  if dst.peerId notin rv2.rsvp:
    trace "refusing connection, no reservation", src, dst = dst.peerId
    await handleHopError(conn, RelayV2Status.NoReservation)
    return

  # TODO: Check max circuit for src and dst
  # + incr accordingly
  # + defer decr

  let connDst = try:
    await rv2.switch.dial(dst.peerId, RelayV2StopCodec)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error opening relay stream", dst, exc=exc.msg
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return
  defer:
    await connDst.close()

  let stopMsgToSend = StopMessage(msgType: StopMessageType.Connect,
                            peer: some(RelayV2Peer(peerId: src, addrs: @[addrs])),
                            limit: some(rv2.limit))

  try:
    await connDst.writeLp(encodeStopMessage(stopMsgToSend).buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing stop handshake", exc=exc.msg
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return

  let msgRcvFromDstOpt = try:
    decodeStopMessage(await connDst.readLp(rv2.msgSize))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error reading stop response", exc=exc.msg
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return

  if msgRcvFromDstOpt.isNone():
    trace "error reading stop response", msg = msgRcvFromDstOpt
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return

  let msgRcvFromDst = msgRcvFromDstOpt.get()
  if msgRcvFromDst.msgType != StopMessageType.Status:
    trace "unexpected stop response, not a status message", msgType = msgRcvFromDst.msgType
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return

  if msgRcvFromDst.status.isNone() or msgRcvFromDst.status.get() != RelayV2Status.Ok:
    trace "relay stop failure", status = msgRcvFromDst.status
    await handleHopError(conn, RelayV2Status.ConnectionFailed)
    return

  let resp = HopMessage(msgType: HopMessageType.Status,
                        status: some(RelayV2Status.Ok))
  try:
    await conn.writeLp(encodeHopMessage(resp).buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing relay response", exc=exc.msg
    return

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
          assert bufRead <= bufferSize
          bytesSendFromSrcToDst.inc(bufRead)
          await connDst.write(@bufSrcToDst[0..<bufRead])
          zeroMem(addr(bufSrcToDst), bufferSize)
          futSrc = conn.readOnce(addr bufSrcToDst[0], bufSrcToDst.high + 1)
        if futDst.finished():
          bufRead = await futDst
          assert bufRead <= bufferSize
          bytesSendFromDstToSrc += bufRead
          await conn.write(bufDstToSrc[0..<bufRead])
          zeroMem(addr(bufDstToSrc), bufferSize)
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

proc heartbeat(rv2: RelayV2) {.async.} =
  while true: # TODO: idk... something?
    let n = now().utc
    var rsvp = rv2.rsvp
    for k, v in rv2.rsvp.mpairs:
      if n > v:
        rsvp.del(k)
    rv2.rsvp = rsvp

    await sleepAsync(chronos.seconds(rv2.heartbeatSleepTime))

proc new*(T: typedesc[RelayV2], switch: Switch): T =
  let rv2 = T(switch: switch)
  rv2.init()
  rv2

proc init*(
  rv2: RelayV2,
  reservationTTL: times.Duration = DefaultReservationTTL,
  limitDuration: uint32 = DefaultLimitDuration,
  limitData: uint64 = DefaultLimitData,
  heartbeatSleepTime: uint32 = DefaultHeartbeatSleepTime,
  msgSize: uint32 = MsgSize) =
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = decodeHopMessage(await conn.readLp(rv2.msgSize))

      if msgOpt.isNone():
        await handleHopError(conn, RelayV2Status.MalformedMessage)
        return
      else:
        trace "relayv2 handle stream", msg = msgOpt.get()
      let msg = msgOpt.get()

      case msg.msgType:
        of HopMessageType.Reserve: await rv2.handleReserve(conn)
        of HopMessageType.Connect: await rv2.handleConnect(conn, msg)
        else:
          trace "Unexpected relayv2 handshake", msgType=msg.msgType
          await handleHopError(conn, RelayV2Status.MalformedMessage)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in relayv2 handler", exc = exc.msg, conn
    finally:
      trace "exiting relayv2 handler", conn
      await conn.close()

  rv2.handler = handleStream
  rv2.codecs = @[RelayV2HopCodec]

  rv2.reservationTTL = reservationTTL
  rv2.limit = RelayV2Limit(duration: limitDuration, data: limitData)
  rv2.heartbeatSleepTime = heartbeatSleepTime
  rv2.msgSize = msgSize

  asyncSpawn rv2.heartbeat()

# Client side

type
  Client* = ref object of LPProtocol
    switch: Switch
    queue: AsyncQueue[Connection]
    # hopCount: Table[PeerID, int]
  ReserveError* = enum
    ReserveFailedDial,
    ReserveFailedConnection,
    ReserveMalformedMessage,
    ReserveBadType,
    ReserveBadStatus,
    ReserveMissingReservation,
    ReserveBadExpirationDate,
    ReserveInvalidVoucher,
    ReserveUnexpected

proc handleStopError(conn: Connection, code: RelayV2Status) {.async.} =
  trace "send stop status", status = $code & " (" & $ord(code) & ")"
  let
    msg = StopMessage(msgType: StopMessageType.Status,
      peer: none(RelayV2Peer),
      limit: none(RelayV2Limit),
      status: some(code))
    pb = encodeStopMessage(msg)

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing error msg", exc=exc.msg, code

proc new*(T: typedesc[Client], switch: Switch): T =
  let cl = T(switch: switch)
  cl.init()
  cl

proc handleConnect(cl: Client, conn: Connection, msg: StopMessage) {.async.} =
  if msg.peer.isNone():
    await handleStopError(conn, RelayV2Status.MalformedMessage)
    return
  let src = msg.peer.get()

  if msg.limit.isSome():
    # Something TODO here
    # + golib does that:
    # + var stat network.ConnStats
    # + stat.Transient = true
    # + stat.Extra[StatLimitDuration] = time.Duration(limit.GetDuration()) * time.Second
    # + stat.Extra[StatLimitData] = limit.GetData()
    discard

  trace "incoming relay connection", src, conn

  let
    msg = StopMessage(
      msgType: StopMessageType.Status,
      peer: none(RelayV2Peer),
      limit: none(RelayV2Limit),
      status: some(RelayV2Status.Ok))
    pb = encodeStopMessage(msg)

  try:
    await conn.writeLp(pb.buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing stop msg", exc=exc.msg
    return
  await cl.queue.addLast(conn)
  await conn.join()

proc init*(cl: Client) =
  # TODO add circuit relay v1 to the handler for backwards compatibility
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = decodeStopMessage(await conn.readLp(MsgSize)) # TODO: configurable

      if msgOpt.isNone():
        await handleHopError(conn, RelayV2Status.MalformedMessage)
        return
      else:
        trace "client handle stream", msg = msgOpt.get()
      let msg = msgOpt.get()

      if msg.msgType == StopMessageType.Connect:
        await cl.handleConnect(conn, msg)
      else:
        trace "Unexpected client / relayv2 handshake", msgType=msg.msgType
        await handleStopError(conn, RelayV2Status.MalformedMessage)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in client handler", exc = exc.msg, conn
    finally:
      trace "exiting client handler", conn
      await conn.close()

  cl.queue = newAsyncQueue[Connection](0)

  cl.handler = handleStream
  cl.codecs = @[RelayV2StopCodec] # TODO: add Circuit RelayV1

proc reserve*(cl: Client, relayPI: PeerInfo): Future[Result[Reservation, ReserveError]] {.async.} =
  var
    msg = HopMessage(msgType: HopMessageType.Reserve)
    msgOpt: Option[HopMessage]
  let pb = encodeHopMessage(msg)

  let conn = try:
    await cl.switch.dial(relayPI.peerId, relayPI.addrs, RelayV2HopCodec)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error opening relay stream", exc=exc.msg, relayPI
    return err(ReserveFailedDial)
  defer:
    await conn.close()

  try:
    await conn.writeLp(pb.buffer)
    msgOpt = decodeHopMessage(await conn.readLp(MsgSize))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing reservation message", exc=exc.msg
    return err(ReserveFailedConnection)

  if msgOpt.isNone():
    trace "Malformed message from relay"
    return err(ReserveMalformedMessage)
  msg = msgOpt.get()
  if msg.msgType != HopMessageType.Status:
    trace "unexpected relay response type", msgType = msg.msgType
    return err(ReserveBadType)
  if msg.status.isNone() or msg.status.get() != Ok:
    trace "reservation failed", status = msg.status
    return err(ReserveBadStatus)

  if msg.reservation.isNone():
    trace "missing reservation info"
    return err(ReserveMissingReservation)
  let rsvp = msg.reservation.get()
  if now().utc > rsvp.expire.int64.fromUnix.utc:
    trace "received reservation with expiration date in the past"
    return err(ReserveBadExpirationDate)
  if rsvp.svoucher.isSome():
    let svoucher = SignedVoucher.decode(rsvp.svoucher.get())
    if svoucher.isErr():
      trace "error consuming voucher envelope", error = svoucher.error
      return err(ReserveInvalidVoucher)

  if msg.limit.isSome():
    discard # TODO: Add those informations to rsvp eventually

  return ok(rsvp)

proc dialPeer(
    cl: Client,
    conn: Connection,
    dstPeerId: PeerID,
    dstAddrs: seq[MultiAddress]): Future[Connection] {.async.} =
  var
    msg = HopMessage(
      msgType: HopMessageType.Connect,
      peer: some(RelayV2Peer(peerId: dstPeerId, addrs: dstAddrs)))
    pb = encodeHopMessage(msg)

  trace "Dial peer", msgSend=msg

  let msgRcvFromRelayOpt = try:
    await conn.writeLp(pb.buffer)
    decodeHopMessage(await conn.readLp(MsgSize)) # TODO: cl.msgSize
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error reading stop response", exc=exc.msg
    raise exc

  if msgRcvFromRelayOpt.isNone():
    trace "error reading stop response", msg = msgRcvFromRelayOpt
    # TODO: raise
    return

  let msgRcvFromRelay = msgRcvFromRelayOpt.get()
  if msgRcvFromRelay.msgType != HopMessageType.Status:
    trace "unexcepted relay stop response", msgType = msgRcvFromRelay.msgType
    # TODO: raise
    return

  if msgRcvFromRelay.status.isNone() or msgRcvFromRelay.status.get() != RelayV2Status.Ok:
    trace "relay stop failure", status=msgRcvFromRelay.status
    # TODO: raise
    return

  # TODO: check limit + do smthg with it

  result = conn

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
  result = await self.client.dialPeer(conn, dstPeerId, @[])

method dial*(
  self: RelayV2Transport,
  hostname: string,
  address: MultiAddress): Future[Connection] {.async, gcsafe.} =
  result = await self.dial(address)

const # TODO Move those two in multiaddress.nim
  P2PPattern = mapEq("p2p")
  CircuitRelay = mapEq("p2p-circuit")

method handles*(self: RelayV2Transport, ma: MultiAddress): bool {.gcsafe} =
  if ma.protocols.isOk():
    let sma = toSeq(ma.items())
    if sma.len >= 3:
      result=(CircuitRelay.match(sma[^2].get()) and P2PPattern.match(sma[^1].get())) or CircuitRelay.match(sma[^1].get())
  trace "Handles return", ma, result

proc new*(T: typedesc[RelayV2Transport], cl: Client, upgrader: Upgrade): T =
  T(client: cl, upgrader: upgrader)

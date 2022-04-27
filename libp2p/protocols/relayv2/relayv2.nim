## Nim-LibP2P
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options
import sequtils, strutils, tables
import chronos, chronicles

import ./voucher,
       ../../peerinfo,
       ../../switch,
       ../../multiaddress,
       ../../multicodec,
       ../../stream/connection,
       ../../protocols/protocol,
       ../../transports/transport,
       ../../utility,
       ../../errors,
       ../../signed_envelope

import std/times # Eventually replace it by chronos/timer

const
  RelayV2HopCodec* = "/libp2p/circuit/relay/0.2.0/hop"
  RelayV2StopCodec* = "/libp2p/circuit/relay/0.2.0/stop"
  MsgSize* = 4096
  DefaultReservationTimeout* = initDuration(hours = 1)

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
    duration: Option[uint32] # seconds
    data: Option[uint64] # bytes

  RelayV2* = ref object of LPProtocol
    switch: Switch
    peerId: PeerID
    rsvp: Table[PeerId, DateTime] # TODO: eventually replace by chronos/timer
    hopCount: CountTable[PeerID]

    reservationTTL: times.Duration # TODO: eventually replace by chronos/timer
    limit: RelayV2Limit
    msgSize*: int # TODO: Verify in the spec if it's configurable

# Hop Protocol

proc encodeHopMessage*(msg: HopMessage): Result[ProtoBuffer, CryptoError] =
  var pb = initProtoBuffer()

  pb.write(1, msg.msgType.ord.uint)
  if isSome(msg.peer):
    var ppb = initProtoBuffer()
    ppb.write(1, msg.peer.get().peerId)
    for ma in msg.peer.get().addrs:
      ppb.write(2, ma.data.buffer)
    ppb.finish()
    pb.write(2, ppb.buffer)
  if isSome(msg.reservation):
    let rsrv = msg.reservation.get()
    var rpb = initProtoBuffer()
    rpb.write(1, rsrv.expire)
    for ma in rsrv.addrs:
      rpb.write(2, ma.data.buffer)
    if isSome(rsrv.svoucher):
      rpb.write(3, rsrv.svoucher.get())
    rpb.finish()
    pb.write(3, rpb.buffer)
  if isSome(msg.limit):
    let limit = msg.limit.get()
    var lpb = initProtoBuffer()
    if isSome(limit.duration):
      lpb.write(1, limit.duration.get())
    if isSome(limit.data):
      lpb.write(2, limit.data.get())
    lpb.finish()
    pb.write(4, lpb.buffer)
  if isSome(msg.status):
    pb.write(5, msg.status.get().ord.uint)

  pb.finish()
  ok(pb)

proc decodeHopMessage(buf: seq[byte]): Option[HopMessage] =
  let pb = initProtoBuffer(buf)
  var
    msg: HopMessage
    msgTypeOrd: uint32
    ppb: ProtoBuffer
    rpb: ProtoBuffer
    lpb: ProtoBuffer
    svoucher: seq[byte]
    statusOrd: uint32
    peer: RelayV2Peer
    reservation: Reservation
    limit: RelayV2Limit
    res: bool

  let
    r1 = pb.getRequiredField(1, msgTypeOrd)
    r2 = pb.getField(2, ppb)
    r3 = pb.getField(3, rpb)
    r4 = pb.getField(4, lpb)
    r5 = pb.getField(5, statusOrd)

  res = r1.isOk() and r2.isOk() and r3.isOk() and r4.isOk() and r5.isOk()

  if r2.isOk() and r2.get():
    let
      r2PeerId = ppb.getField(1, peer.peerId)
      r2Addrs = ppb.getRepeatedField(2, peer.addrs)
    res = res and r2PeerId.isOk() and r2Addrs.isOk()
  if r3.isOk() and r3.get():
    let
      r3Expire = rpb.getRequiredField(1, reservation.expire)
      r3Addrs = rpb.getRepeatedField(2, reservation.addrs)
      r3SVoucher = rpb.getField(3, svoucher)
    if r3SVoucher.isOk() and r3SVoucher.get():
      reservation.svoucher = some(svoucher)
    res = res and r3Expire.isOk() and r3Addrs.isOk() and r3SVoucher.isOk()
  if r4.isOk() and r4.get():
    var
      lduration: uint32
      ldata: uint64
    let
      r4Duration = lpb.getField(1, lduration)
      r4Data = lpb.getField(2, ldata)
    if r4Duration.isOk() and r4Duration.get(): limit.duration = some(lduration)
    if r4Data.isOk() and r4Data.get(): limit.data = some(ldata)
    res = res and r4Duration.isOk() and r4Data.isOk()

  if res:
    msg.msgType = HopMessageType(msgTypeOrd)
    if r2.get():
      msg.peer = some(peer)
    if r3.get():
      msg.reservation = some(reservation)
    if r4.get():
      msg.limit = some(limit)
    if r5.get():
      msg.status = some(RelayV2Status(statusOrd))
    some(msg)
  else:
    HopMessage.none

proc handleError*(conn: Connection, code: RelayV2Status) {.async, gcsafe.} =
  trace "send status", status = $code & "(" & $ord(code) & ")"
  let
    msg = HopMessage(msgType: HopMessageType.Status,
      peer: none(RelayV2Peer),
      reservation: none(Reservation),
      limit: none(RelayV2Limit),
      status: some(code))
    pb = encodeHopMessage(msg)

  if pb.isOk:
    await conn.writeLp(pb.get().buffer)
  else:
    # This should never happen
    error "error encoding relay response", error = $pb

# Stop Message

proc encodeStopMessage(msg: StopMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.msgType.ord.uint)
  if isSome(msg.peer):
    var ppb = initProtoBuffer()
    ppb.write(1, msg.peer.get().peerId)
    for ma in msg.peer.get().addrs:
      ppb.write(2, ma.data.buffer)
    ppb.finish()
    pb.write(2, ppb.buffer)
  if isSome(msg.limit):
    let limit = msg.limit.get()
    var lpb = initProtoBuffer()
    if isSome(limit.duration):
      lpb.write(1, limit.duration.get())
    if isSome(limit.data):
      lpb.write(2, limit.data.get())
    lpb.finish()
    pb.write(3, lpb.buffer)
  if isSome(msg.status):
    pb.write(4, msg.status.get().ord.uint)

  pb.finish()
  pb

proc decodeStopMessage(buf: seq[byte]): Option[StopMessage] =
  let pb = initProtoBuffer(buf)
  var
    msg: StopMessage
    msgTypeOrd: uint32
    ppb: ProtoBuffer
    vpb: ProtoBuffer
    lpb: ProtoBuffer
    statusOrd: uint32
    peer: RelayV2Peer
    reservation: Reservation
    limit: RelayV2Limit
    rVoucher: ProtoResult[bool]
    res: bool

  let
    r1 = pb.getRequiredField(1, msgTypeOrd)
    r2 = pb.getField(2, ppb)
    r3 = pb.getField(3, lpb)
    r4 = pb.getField(4, statusOrd)

  res = r1.isOk() and r2.isOk() and r3.isOk() and r4.isOk()

  if r2.isOk() and r2.get():
    let
      r2PeerId = ppb.getField(1, peer.peerId)
      r2Addrs = ppb.getRepeatedField(2, peer.addrs)
    res = res and r2PeerId.isOk() and r2Addrs.isOk()
  if r3.isOk() and r3.get():
    var
      lduration: uint32
      ldata: uint64
    let
      r3Duration = lpb.getField(1, lduration)
      r3Data = lpb.getField(2, ldata)
    if r3Duration.isOk() and r3Duration.get(): limit.duration = some(lduration)
    if r3Data.isOk() and r3Data.get(): limit.data = some(ldata)
    res = res and r3Duration.isOk() and r3Data.isOk()

  if res:
    msg.msgType = StopMessageType(msgTypeOrd)
    if r2.get():
      msg.peer = some(peer)
    if r3.get():
      msg.limit = some(limit)
    if r4.get():
      msg.status = some(RelayV2Status(statusOrd))
    some(msg)
  else:
    StopMessage.none

# Protocols

proc createHopMessage(
    rv2: RelayV2,
    pid: PeerID,
    expire: DateTime): Result[HopMessage, CryptoError] =
  var msg: HopMessage
  let expireUnix = expire.toTime.toUnix.uint64 # maybe weird integer conversion
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
    await handleError(conn, RelayV2Status.PermissionDenied)
    return

  # TODO: Access Control List check, eventually

  let expire = now().utc + rv2.reservationTTL
  rv2.rsvp[pid] = expire

  trace "reserving relay slot for", pid

  let msg = rv2.createHopMessage(pid, expire)
  if isErr(msg):
    trace "error signing the voucher", error = error(msg), pid, addrs
    # conn.reset()
    return
  let pb = encodeHopMessage(msg.get())
  if isErr(pb):
    trace "error signing the voucher", error = error(pb), msg
    # conn.reset()
    return
  try:
    await conn.writeLp(pb.get().buffer)
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "error writing reservation response", exc=exc.msg, retractedPid = pid
    # conn.reset()

proc handleConnect(rv2: Relayv2, conn: Connection, msg: HopMessage) {.async, gcsafe.} =
  discard

proc new*(T: typedesc[RelayV2], switch: Switch): T =
  T(switch = switch)

proc init(rv2: RelayV2) =
  proc handleStream(conn: Connection, proto: string) {.async, gcsafe.} =
    try:
      let msgOpt = decodeHopMessage(await conn.readLp(rv2.msgSize))

      if msgOpt.isNone:
        await handleError(conn, RelayV2Status.MalformedMessage)
        return
      else:
        trace "relayv2 handle stream", msg = msgOpt.get()
      let msg = msgOpt.get()

      if msg.msgType == HopMessageType.Reserve:
        await rv2.handleReserve(conn)
      elif msg.msgType == HopMessageType.Connect:
        await rv2.handleConnect(conn, msg)
      else:
        trace "Unexpected relayv2 handshake", msgType=msg.msgType
        await handleError(conn, RelayV2Status.MalformedMessage)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      trace "exception in relayv2 handler", exc = exc.msg, conn
    finally:
      trace "exiting relayv2 handler", conn
      await conn.close()

  rv2.handler = handleStream
  rv2.codecs = @[RelayV2HopCodec]

  # make all this configurable
  rv2.reservationTTL = DefaultReservationTimeout
  rv2.limit = RelayV2Limit(duration: some(120u32), data: some(1u64 shr 17))

  rv2.msgSize = MsgSize

# Client side

type
  Client = ref object of Transport
    switch: Switch
    # activeDials: Table[PeerID, Completion] # ??
    # hopCount: Table[PeerID, int]

proc new(T: typedesc[Client], switch: Switch): T =
  T(swith = switch)

proc reserve(src: Switch, relayPI: PeerInfo): Future[Result[Reservation, RelayV2Error]] {.async.} =
  let conn = await src.dial(relayPI.peerId, relayPI.addrs, RelayV2HopCodec)
  let msg = HopMessage(msgType: HopMessageType.Reserve)
  let pb = encodeHopMessage(msg)
  if pb.isErr():
    error "Encode hop message during client side reserve", msg
    return
  await conn.writeLp(pb.get().buffer)
  let responseMsgOpt = decodeHopMessage(await conn.readLp(MsgSize))
  if responseMsgOpt.isNone():
    trace "Malformed message from relay"
    return err(RelayV2Error()) # TODO: To change because it's reaaally bad
  let responseMsg = responseMsgOpt.get()
  if responseMsg.msgType != HopMessageType.Status:
    trace "unexpected relay response type", msgType = responseMsg.msgType
    return err(RelayV2Error())
  if responseMsg.status.isNone() or responseMsg.status.get() != Ok:
    trace "reservation failed", status = responseMsg.status
    return err(RelayV2Error())
  if responseMsg.reservation.isNone():
    trace "missing reservation info"
    return err(RelayV2Error())
  let rsvp = responseMsg.reservation.get()
  if now().utc < rsvp.expire.int64.fromUnix.utc: # unsure
    trace "received reservation with expiration date in the past"
    return err(RelayV2Error())
  if rsvp.svoucher.isSome():
    let svoucher = SignedVoucher.decode(rsvp.svoucher.get())
    if svoucher.isErr():
      trace "error consuming voucher envelope", error = svoucher.error
  discard

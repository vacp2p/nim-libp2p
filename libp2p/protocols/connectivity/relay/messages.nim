# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import macros
import stew/[objects, results]
import ../../../peerinfo,
       ../../../signed_envelope

# Circuit Relay V1 Message

type
  RelayType* {.pure.} = enum
    Hop = 1
    Stop = 2
    Status = 3
    CanHop = 4

  StatusV1* {.pure.} = enum
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

  RelayPeer* = object
    peerId*: PeerId
    addrs*: seq[MultiAddress]

  RelayMessage* = object
    msgType*: Opt[RelayType]
    srcPeer*: Opt[RelayPeer]
    dstPeer*: Opt[RelayPeer]
    status*: Opt[StatusV1]

proc encode*(msg: RelayMessage): ProtoBuffer =
  result = initProtoBuffer()

  msg.msgType.withValue(typ):
    result.write(1, typ.ord.uint)
  msg.srcPeer.withValue(srcPeer):
    var peer = initProtoBuffer()
    peer.write(1, srcPeer.peerId)
    for ma in srcPeer.addrs:
      peer.write(2, ma.data.buffer)
    peer.finish()
    result.write(2, peer.buffer)
  msg.dstPeer.withValue(dstPeer):
    var peer = initProtoBuffer()
    peer.write(1, dstPeer.peerId)
    for ma in dstPeer.addrs:
      peer.write(2, ma.data.buffer)
    peer.finish()
    result.write(3, peer.buffer)
  msg.status.withValue(status):
    result.write(4, status.ord.uint)

  result.finish()

proc decode*(_: typedesc[RelayMessage], buf: seq[byte]): Opt[RelayMessage] =
  var
    rMsg: RelayMessage
    msgTypeOrd: uint32
    src: RelayPeer
    dst: RelayPeer
    statusOrd: uint32
    pbSrc: ProtoBuffer
    pbDst: ProtoBuffer

  let pb = initProtoBuffer(buf)

  if ? pb.getField(1, msgTypeOrd).toOpt():
    if msgTypeOrd.int notin RelayType:
      return Opt.none(RelayMessage)
    rMsg.msgType = Opt.some(RelayType(msgTypeOrd))

  if ? pb.getField(2, pbSrc).toOpt():
    discard ? pbSrc.getField(1, src.peerId).toOpt()
    discard ? pbSrc.getRepeatedField(2, src.addrs).toOpt()
    rMsg.srcPeer = Opt.some(src)

  if ? pb.getField(3, pbDst).toOpt():
    discard ? pbDst.getField(1, dst.peerId).toOpt()
    discard ? pbDst.getRepeatedField(2, dst.addrs).toOpt()
    rMsg.dstPeer = Opt.some(dst)

  if ? pb.getField(4, statusOrd).toOpt():
    var status: StatusV1
    if not checkedEnumAssign(status, statusOrd):
      return Opt.none(RelayMessage)
    rMsg.status = Opt.some(status)
  Opt.some(rMsg)

# Voucher

type
  Voucher* = object
    relayPeerId*: PeerId     # peer ID of the relay
    reservingPeerId*: PeerId # peer ID of the reserving peer
    expiration*: uint64      # UNIX UTC expiration time for the reservation

proc decode*(_: typedesc[Voucher], buf: seq[byte]): Result[Voucher, ProtoError] =
  let pb = initProtoBuffer(buf)
  var v = Voucher()

  ? pb.getRequiredField(1, v.relayPeerId)
  ? pb.getRequiredField(2, v.reservingPeerId)
  ? pb.getRequiredField(3, v.expiration)

  ok(v)

proc encode*(v: Voucher): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, v.relayPeerId)
  pb.write(2, v.reservingPeerId)
  pb.write(3, v.expiration)

  pb.finish()
  pb.buffer

proc init*(T: typedesc[Voucher],
          relayPeerId: PeerId,
          reservingPeerId: PeerId,
          expiration: uint64): T =
  T(
    relayPeerId = relayPeerId,
    reservingPeerId = reservingPeerId,
    expiration: expiration
  )

type SignedVoucher* = SignedPayload[Voucher]

proc payloadDomain*(_: typedesc[Voucher]): string = "libp2p-relay-rsvp"
proc payloadType*(_: typedesc[Voucher]): seq[byte] = @[ (byte)0x03, (byte)0x02 ]

proc checkValid*(spr: SignedVoucher): Result[void, EnvelopeError] =
  if not spr.data.relayPeerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

# Circuit Relay V2 Hop Message

type
  Peer* = object
    peerId*: PeerId
    addrs*: seq[MultiAddress]
  Reservation* = object
    expire*: uint64              # required, Unix expiration time (UTC)
    addrs*: seq[MultiAddress]    # relay address for reserving peer
    svoucher*: Opt[seq[byte]]    # optional, reservation voucher
  Limit* = object
    duration*: uint32            # seconds
    data*: uint64                # bytes

  StatusV2* = enum
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
    peer*: Opt[Peer]
    reservation*: Opt[Reservation]
    limit*: Limit
    status*: Opt[StatusV2]

proc encode*(msg: HopMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.msgType.ord.uint)
  msg.peer.withValue(peer):
    var ppb = initProtoBuffer()
    ppb.write(1, peer.peerId)
    for ma in peer.addrs:
      ppb.write(2, ma.data.buffer)
    ppb.finish()
    pb.write(2, ppb.buffer)
  msg.reservation.withValue(rsrv):
    var rpb = initProtoBuffer()
    rpb.write(1, rsrv.expire)
    for ma in rsrv.addrs:
      rpb.write(2, ma.data.buffer)
    rsrv.svoucher.withValue(vouch):
      rpb.write(3, vouch)
    rpb.finish()
    pb.write(3, rpb.buffer)
  if msg.limit.duration > 0 or msg.limit.data > 0:
    var lpb = initProtoBuffer()
    if msg.limit.duration > 0: lpb.write(1, msg.limit.duration)
    if msg.limit.data > 0: lpb.write(2, msg.limit.data)
    lpb.finish()
    pb.write(4, lpb.buffer)
  msg.status.withValue(status):
    pb.write(5, status.ord.uint)

  pb.finish()
  pb

proc decode*(_: typedesc[HopMessage], buf: seq[byte]): Opt[HopMessage] =
  var msg: HopMessage
  let pb = initProtoBuffer(buf)

  var msgTypeOrd: uint32
  ? pb.getRequiredField(1, msgTypeOrd).toOpt()
  if not checkedEnumAssign(msg.msgType, msgTypeOrd):
    return Opt.none(HopMessage)

  var pbPeer: ProtoBuffer
  if ? pb.getField(2, pbPeer).toOpt():
    var peer: Peer
    ? pbPeer.getRequiredField(1, peer.peerId).toOpt()
    discard ? pbPeer.getRepeatedField(2, peer.addrs).toOpt()
    msg.peer = Opt.some(peer)

  var pbReservation: ProtoBuffer
  if ? pb.getField(3, pbReservation).toOpt():
    var
      svoucher: seq[byte]
      reservation: Reservation
    if ? pbReservation.getField(3, svoucher).toOpt():
      reservation.svoucher = Opt.some(svoucher)
    ? pbReservation.getRequiredField(1, reservation.expire).toOpt()
    discard ? pbReservation.getRepeatedField(2, reservation.addrs).toOpt()
    msg.reservation = Opt.some(reservation)

  var pbLimit: ProtoBuffer
  if ? pb.getField(4, pbLimit).toOpt():
    discard ? pbLimit.getField(1, msg.limit.duration).toOpt()
    discard ? pbLimit.getField(2, msg.limit.data).toOpt()

  var statusOrd: uint32
  if ? pb.getField(5, statusOrd).toOpt():
    var status: StatusV2
    if not checkedEnumAssign(status, statusOrd):
      return Opt.none(HopMessage)
    msg.status = Opt.some(status)
  Opt.some(msg)

# Circuit Relay V2 Stop Message

type
  StopMessageType* {.pure.} = enum
    Connect = 0
    Status = 1
  StopMessage* = object
    msgType*: StopMessageType
    peer*: Opt[Peer]
    limit*: Limit
    status*: Opt[StatusV2]


proc encode*(msg: StopMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.msgType.ord.uint)
  msg.peer.withValue(peer):
    var ppb = initProtoBuffer()
    ppb.write(1, peer.peerId)
    for ma in peer.addrs:
      ppb.write(2, ma.data.buffer)
    ppb.finish()
    pb.write(2, ppb.buffer)
  if msg.limit.duration > 0 or msg.limit.data > 0:
    var lpb = initProtoBuffer()
    if msg.limit.duration > 0: lpb.write(1, msg.limit.duration)
    if msg.limit.data > 0: lpb.write(2, msg.limit.data)
    lpb.finish()
    pb.write(3, lpb.buffer)
  msg.status.withValue(status):
    pb.write(4, status.ord.uint)

  pb.finish()
  pb

proc decode*(_: typedesc[StopMessage], buf: seq[byte]): Opt[StopMessage] =
  var msg: StopMessage

  let pb = initProtoBuffer(buf)

  var msgTypeOrd: uint32
  ? pb.getRequiredField(1, msgTypeOrd).toOpt()
  if msgTypeOrd.int notin StopMessageType:
    return Opt.none(StopMessage)
  msg.msgType = StopMessageType(msgTypeOrd)


  var pbPeer: ProtoBuffer
  if ? pb.getField(2, pbPeer).toOpt():
    var peer: Peer
    ? pbPeer.getRequiredField(1, peer.peerId).toOpt()
    discard ? pbPeer.getRepeatedField(2, peer.addrs).toOpt()
    msg.peer = Opt.some(peer)

  var pbLimit: ProtoBuffer
  if ? pb.getField(3, pbLimit).toOpt():
    discard ? pbLimit.getField(1, msg.limit.duration).toOpt()
    discard ? pbLimit.getField(2, msg.limit.data).toOpt()

  var statusOrd: uint32
  if ? pb.getField(4, statusOrd).toOpt():
    var status: StatusV2
    if not checkedEnumAssign(status, statusOrd):
      return Opt.none(StopMessage)
    msg.status = Opt.some(status)
  Opt.some(msg)

## Nim-LibP2P
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import options

import ../../peerinfo,
       ../../signed_envelope

# Voucher

type
  Voucher* = object
    relayPeerId*: PeerID     # peer ID of the relay
    reservingPeerId*: PeerID # peer ID of the reserving peer
    expiration*: uint64      # UNIX UTC expiration time for the reservation

proc decode*(T: typedesc[Voucher], buf: seq[byte]): Result[Voucher, ProtoError] =
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
          relayPeerId: PeerID,
          reservingPeerId: PeerID,
          expiration: uint64): T =
  T(
    relayPeerId = relayPeerId,
    reservingPeerId = reservingPeerId,
    expiration: expiration
  )

type SignedVoucher* = SignedPayload[Voucher]

proc payloadDomain*(T: typedesc[Voucher]): string = "libp2p-relay-rsvp"
proc payloadType*(T: typedesc[Voucher]): seq[byte] = @[ (byte)0x03, (byte)0x02 ]

proc checkValid*(spr: SignedVoucher): Result[void, EnvelopeError] =
  if not spr.data.relayPeerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

# HopMessage

type
  Peer* = object
    peerId*: PeerID
    addrs*: seq[MultiAddress]
  Reservation* = object
    expire*: uint64              # required, Unix expiration time (UTC)
    addrs*: seq[MultiAddress]    # relay address for reserving peer
    svoucher*: Option[seq[byte]] # optional, reservation voucher
  Limit* = object
    duration*: uint32            # seconds
    data*: uint64                # bytes

  Status* = enum
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
    peer*: Option[Peer]
    reservation*: Option[Reservation]
    limit*: Limit
    status*: Option[Status]

proc encode*(msg: HopMessage): ProtoBuffer =
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
  if msg.limit.duration > 0 or msg.limit.data > 0:
    var lpb = initProtoBuffer()
    if msg.limit.duration > 0: lpb.write(1, msg.limit.duration)
    if msg.limit.data > 0: lpb.write(2, msg.limit.data)
    lpb.finish()
    pb.write(4, lpb.buffer)
  if msg.status.isSome():
    pb.write(5, msg.status.get().ord.uint)

  pb.finish()
  pb

proc decode*(_: typedesc[HopMessage], buf: seq[byte]): Option[HopMessage] =
  var
    msg: HopMessage
    msgTypeOrd: uint32
    pbPeer: ProtoBuffer
    pbReservation: ProtoBuffer
    pbLimit: ProtoBuffer
    statusOrd: uint32
    peer: Peer
    reservation: Reservation
    limit: Limit
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
      pbLimit.getField(2, limit.data).isErr()):
    return none(HopMessage)

  msg.msgType = HopMessageType(msgTypeOrd)
  if r2.get(): msg.peer = some(peer)
  if r3.get(): msg.reservation = some(reservation)
  if r4.get(): msg.limit = limit
  if r5.get(): msg.status = some(Status(statusOrd))
  some(msg)

# Stop Message

type
  StopMessageType* {.pure.} = enum
    Connect = 0
    Status = 1
  StopMessage* = object
    msgType*: StopMessageType
    peer*: Option[Peer]
    limit*: Limit
    status*: Option[Status]


proc encode*(msg: StopMessage): ProtoBuffer =
  var pb = initProtoBuffer()

  pb.write(1, msg.msgType.ord.uint)
  if msg.peer.isSome():
    var ppb = initProtoBuffer()
    ppb.write(1, msg.peer.get().peerId)
    for ma in msg.peer.get().addrs:
      ppb.write(2, ma.data.buffer)
    ppb.finish()
    pb.write(2, ppb.buffer)
  if msg.limit.duration > 0 or msg.limit.data > 0:
    var lpb = initProtoBuffer()
    if msg.limit.duration > 0: lpb.write(1, msg.limit.duration)
    if msg.limit.data > 0: lpb.write(2, msg.limit.data)
    lpb.finish()
    pb.write(3, lpb.buffer)
  if msg.status.isSome():
    pb.write(4, msg.status.get().ord.uint)

  pb.finish()
  pb

proc decode*(_: typedesc[StopMessage], buf: seq[byte]): Option[StopMessage] =
  var
    msg: StopMessage
    msgTypeOrd: uint32
    pbPeer: ProtoBuffer
    pbLimit: ProtoBuffer
    statusOrd: uint32
    peer: Peer
    limit: Limit
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
      pbLimit.getField(2, limit.data).isErr()):
    return none(StopMessage)

  msg.msgType = StopMessageType(msgTypeOrd)
  if r2.get(): msg.peer = some(peer)
  if r3.get(): msg.limit = limit
  if r4.get(): msg.status = some(Status(statusOrd))
  some(msg)

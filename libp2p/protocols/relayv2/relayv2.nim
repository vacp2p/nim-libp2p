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
       ../../stream/connection,
       ../../protocols/protocol,
       ../../utility,
       ../../errors,
       ../../signed_envelope

const
  RelayV2HopCodec* = "/libp2p/circuit/relay/0.2.0/hop"
  RelayV2StopCodec* = "/libp2p/circuit/relay/0.2.0/stop"

logScope:
  topics = "libp2p relayv2"

type
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
    svoucher: Option[SignedVoucher] # optional, reservation voucher
  RelayV2Limit* = object
    duration: Option[uint32] # seconds
    data: Option[uint64] # bytes

# Hop Protocol

proc encodeHopMessage(msg: HopMessage): Result[ProtoBuffer, CryptoError] =
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
      rpb.write(3, ? rsrv.svoucher.get().encode())
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
    rVoucher = rpb.getField(3, vpb)
    if rVoucher.isOk() and rVoucher.get():
      let signedVoucher = SignedVoucher.decode(vpb.buffer)
      if signedVoucher.isOk():
        reservation.svoucher = some(signedVoucher.get())
      else:
        res = false
    res = res and r3Expire.isOk() and r3Addrs.isOk() and rVoucher.isOk()
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

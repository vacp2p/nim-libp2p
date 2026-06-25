# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import results
import
  protobuf_serialization,
  protobuf_serialization/pkg/results,
  protobuf_serialization/std/enums,
  ../../../peerinfo,
  ../../../signed_envelope,
  ../../../utils/protobuf

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

  RelayPeer* {.proto2.} = object
    peerId* {.fieldNumber: 1, required, ext.}: PeerId
    addrs* {.fieldNumber: 2, ext.}: seq[MultiAddress]

  RelayMessage* {.proto2.} = object
    msgType* {.fieldNumber: 1, ext.}: Opt[RelayType]
    srcPeer* {.fieldNumber: 2.}: Opt[RelayPeer]
    dstPeer* {.fieldNumber: 3.}: Opt[RelayPeer]
    status* {.fieldNumber: 4, ext.}: Opt[StatusV1]

Protobuf.serializerFor([RelayPeer])
Protobuf.serializerFor([RelayMessage], withMetrics = true, domain = "relay-v1")

# Circuit Relay V2 Messages

type
  Voucher* {.proto3.} = object
    relayPeerId* {.fieldNumber: 1, ext.}: Opt[PeerId]
    reservingPeerId* {.fieldNumber: 2, ext.}: Opt[PeerId]
    expiration* {.fieldNumber: 3, pint.}: Opt[uint64]

  Peer* {.proto3.} = object
    peerId* {.fieldNumber: 1, ext.}: Opt[PeerId]
    addrs* {.fieldNumber: 2, ext.}: seq[MultiAddress]

  Reservation* {.proto3.} = object
    expire* {.fieldNumber: 1, pint.}: Opt[uint64]
    addrs* {.fieldNumber: 2, ext.}: seq[MultiAddress]
    svoucher* {.fieldNumber: 3.}: Opt[seq[byte]]

  Limit* {.proto3.} = object
    duration* {.fieldNumber: 1, pint.}: uint32
    data* {.fieldNumber: 2, pint.}: uint64

  StatusV2* = enum
    Unused = 0 # needed for protobuf
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

  HopMessage* {.proto3.} = object
    msgType* {.fieldNumber: 1, ext.}: Opt[HopMessageType]
    peer* {.fieldNumber: 2.}: Opt[Peer]
    reservation* {.fieldNumber: 3.}: Opt[Reservation]
    limit* {.fieldNumber: 4.}: Opt[Limit]
    status* {.fieldNumber: 5, ext.}: Opt[StatusV2]

  StopMessageType* {.pure.} = enum
    Connect = 0
    Status = 1

  StopMessage* {.proto3.} = object
    msgType* {.fieldNumber: 1, ext.}: Opt[StopMessageType]
    peer* {.fieldNumber: 2.}: Opt[Peer]
    limit* {.fieldNumber: 3.}: Opt[Limit]
    status* {.fieldNumber: 4, ext.}: Opt[StatusV2]

Protobuf.serializerFor([Peer, Reservation, Limit, Voucher])
Protobuf.serializerFor(
  [StopMessage, HopMessage], withMetrics = true, domain = "relay-v2"
)

proc init*(
    T: typedesc[Voucher],
    relayPeerId: PeerId,
    reservingPeerId: PeerId,
    expiration: uint64,
): T =
  T(
    relayPeerId: Opt.some(relayPeerId),
    reservingPeerId: Opt.some(reservingPeerId),
    expiration: Opt.some(expiration),
  )

type SignedVoucher* = SignedPayload[Voucher]

proc payloadDomain*(_: typedesc[Voucher]): string =
  "libp2p-relay-rsvp"

proc payloadType*(_: typedesc[Voucher]): seq[byte] =
  @[(byte) 0x03, (byte) 0x02]

proc checkValid*(spr: SignedVoucher): Result[void, EnvelopeError] =
  let relayPeerId = spr.data.relayPeerId.valueOr:
    return err(EnvelopeFieldMissing)
  if spr.data.reservingPeerId.isNone or spr.data.expiration.isNone:
    return err(EnvelopeFieldMissing)

  if not relayPeerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

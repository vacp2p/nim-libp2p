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
    uset = 0 # needed for protobuf
    Hop = 1
    Stop = 2
    Status = 3
    CanHop = 4

  StatusV1* {.pure.} = enum
    uset = 0 # needed for protobuf
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

  RelayPeer* {.proto3.} = object
    peerId* {.fieldNumber: 1, ext.}: PeerId
    addrs* {.fieldNumber: 2, ext.}: seq[MultiAddress]

  RelayMessage* {.proto3.} = object
    msgType* {.fieldNumber: 1, ext.}: Opt[RelayType]
    srcPeer* {.fieldNumber: 2.}: Opt[RelayPeer]
    dstPeer* {.fieldNumber: 3.}: Opt[RelayPeer]
    status* {.fieldNumber: 4, ext.}: Opt[StatusV1]

  Voucher* {.proto3.} = object
    relayPeerId* {.fieldNumber: 1, ext.}: PeerId
    reservingPeerId* {.fieldNumber: 2, ext.}: PeerId
    expiration* {.fieldNumber: 3, pint.}: uint64

Protobuf.serializerFor([RelayPeer, RelayMessage, Voucher])

proc init*(
    T: typedesc[Voucher],
    relayPeerId: PeerId,
    reservingPeerId: PeerId,
    expiration: uint64,
): T =
  T(relayPeerId: relayPeerId, reservingPeerId: reservingPeerId, expiration: expiration)

type SignedVoucher* = SignedPayload[Voucher]

proc payloadDomain*(_: typedesc[Voucher]): string =
  "libp2p-relay-rsvp"

proc payloadType*(_: typedesc[Voucher]): seq[byte] =
  @[(byte) 0x03, (byte) 0x02]

proc checkValid*(spr: SignedVoucher): Result[void, EnvelopeError] =
  if not spr.data.relayPeerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

# Circuit Relay V2 Messages

type
  Peer* {.proto3.} = object
    peerId* {.fieldNumber: 1, ext.}: PeerId
    addrs* {.fieldNumber: 2, ext.}: seq[MultiAddress]

  Reservation* {.proto3.} = object
    expire* {.fieldNumber: 1, pint.}: uint64
    addrs* {.fieldNumber: 2, ext.}: seq[MultiAddress]
    svoucher* {.fieldNumber: 3.}: Opt[seq[byte]]

  Limit* {.proto3.} = object
    duration* {.fieldNumber: 1, pint.}: uint32
    data* {.fieldNumber: 2, pint.}: uint64

  StatusV2* = enum
    uset = 0 # needed for protobuf
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
    msgType* {.fieldNumber: 1, ext.}: HopMessageType
    peer* {.fieldNumber: 2.}: Opt[Peer]
    reservation* {.fieldNumber: 3.}: Opt[Reservation]
    limit* {.fieldNumber: 4.}: Opt[Limit]
    status* {.fieldNumber: 5, ext.}: Opt[StatusV2]

  StopMessageType* {.pure.} = enum
    Connect = 0
    Status = 1

  StopMessage* {.proto3.} = object
    msgType* {.fieldNumber: 1, ext.}: StopMessageType
    peer* {.fieldNumber: 2.}: Opt[Peer]
    limit* {.fieldNumber: 3.}: Opt[Limit]
    status* {.fieldNumber: 4, ext.}: Opt[StatusV2]

Protobuf.serializerFor([Peer, Reservation, Limit, HopMessage, StopMessage])

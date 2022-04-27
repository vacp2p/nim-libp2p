## Nim-LibP2P
## Copyright (c) 2022 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import ../../peerinfo,
       ../../signed_envelope

type
  Voucher* = object
    relayPeerId*: PeerID # peer ID of the relay
    reservingPeerId*: PeerID # peer ID of the reserving peer
    expiration*: uint64 # UNIX UTC expiration time for the reservation

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

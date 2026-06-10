# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## This module implements Routing Records.

{.push raises: [].}

import std/[sequtils, times]
import pkg/results
import multiaddress, multicodec, peerid, signed_envelope
import protobuf_serialization
import utils/protobuf

export peerid, multiaddress, signed_envelope

type
  AddressInfo* {.proto2.} = object
    address* {.fieldNumber: 1, required, ext.}: MultiAddress

  PeerRecord* {.proto2.} = object
    peerId* {.fieldNumber: 1, required, ext.}: PeerId
    seqNo* {.fieldNumber: 2, required, pint.}: uint64
    addresses* {.fieldNumber: 3, required.}: seq[AddressInfo]

Protobuf.serializerFor([AddressInfo, PeerRecord])

proc init*(
    T: typedesc[PeerRecord],
    peerId: PeerId,
    addresses: seq[MultiAddress],
    seqNo = getTime().toUnix().uint64,
      # follows the recommended implementation, using unix epoch as seq no.
): T =
  PeerRecord(
    peerId: peerId, seqNo: seqNo, addresses: addresses.mapIt(AddressInfo(address: it))
  )

## Functions related to signed peer records
type SignedPeerRecord* = SignedPayload[PeerRecord]

proc payloadDomain*(T: typedesc[PeerRecord]): string =
  $multiCodec("libp2p-peer-record")

proc payloadType*(T: typedesc[PeerRecord]): seq[byte] =
  @[(byte) 0x03, (byte) 0x01]

proc checkValid*(spr: SignedPeerRecord): Result[void, EnvelopeError] =
  if not spr.data.peerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

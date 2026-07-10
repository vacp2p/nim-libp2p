# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## This module implements Routing Records.

{.push raises: [].}

import std/[sequtils, times]
import pkg/results
import multiaddress, multicodec, peerid, signed_envelope
import protobuf_serialization

export peerid, multiaddress, signed_envelope

type
  AddressInfo* {.proto3.} = object
    address* {.fieldNumber: 1, ext.}: MultiAddress

  PeerRecord* {.proto3.} = object
    peerId* {.fieldNumber: 1, ext.}: PeerId
    seqNo* {.fieldNumber: 2, pint.}: uint64
    addresses* {.fieldNumber: 3.}: seq[AddressInfo]

proc encode*(pr: PeerRecord): seq[byte] =
  Protobuf.encode(pr)

proc checkAddresses*(addresses: seq[AddressInfo]): Result[void, string] =
  for ai in addresses:
    if ai.address.data.buffer.len == 0 or not ai.address.validate():
      return err("invalid address")
  ok()

proc decode*(T: typedesc[PeerRecord], buf: seq[byte]): Result[PeerRecord, string] =
  let record =
    try:
      Protobuf.decode(buf, PeerRecord)
    except SerializationError as e:
      return err("failed to decode PeerRecord. " & e.msg)

  if record.peerId.len == 0:
    return err("failed to decode PeerRecord. missing peer id")

  record.addresses.checkAddresses().isOkOr:
    return err("failed to decode PeerRecord. " & error)

  ok(record)

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

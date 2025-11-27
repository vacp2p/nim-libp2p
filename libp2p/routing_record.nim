# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

## This module implements Routing Records.

{.push raises: [].}

import std/[sequtils, times]
import pkg/results
import multiaddress, multicodec, peerid, protobuf/minprotobuf, signed_envelope

export peerid, multiaddress, signed_envelope

type
  AddressInfo* = object
    address*: MultiAddress

  PeerRecord* = object
    peerId*: PeerId
    seqNo*: uint64
    addresses*: seq[AddressInfo]
    mixKey*: seq[byte]

proc decode*(
    T: typedesc[PeerRecord], buffer: seq[byte]
): Result[PeerRecord, ProtoError] =
  let pb = initProtoBuffer(buffer)
  var record = PeerRecord()

  ?pb.getRequiredField(1, record.peerId)
  ?pb.getRequiredField(2, record.seqNo)

  var addressInfos: seq[seq[byte]]
  if ?pb.getRepeatedField(3, addressInfos):
    for address in addressInfos:
      var addressInfo = AddressInfo()
      let subProto = initProtoBuffer(address)
      let f = subProto.getField(1, addressInfo.address)
      if f.get(false):
        record.addresses &= addressInfo

    if record.addresses.len == 0:
      return err(ProtoError.RequiredFieldMissing)

  ?pb.getField(4, record.mixKey)

  ok(record)

proc encode*(record: PeerRecord): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, record.peerId)
  pb.write(2, record.seqNo)

  for address in record.addresses:
    var addrPb = initProtoBuffer()
    addrPb.write(1, address.address)
    pb.write(3, addrPb)

  pb.write(4, record.mixKey)

  pb.finish()
  pb.buffer

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

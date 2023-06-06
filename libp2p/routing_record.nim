# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module implements Routing Records.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[sequtils, times]
import pkg/stew/results
import
  multiaddress,
  multicodec,
  peerid,
  protobuf/minprotobuf,
  signed_envelope

export peerid, multiaddress, signed_envelope

type
  AddressInfo* = object
    address*: MultiAddress

  PeerRecord* = object
    peerId*: PeerId
    seqNo*: uint64
    addresses*: seq[AddressInfo]

proc decode*(
  T: typedesc[PeerRecord],
  buffer: seq[byte]): Result[PeerRecord, ProtoError] =

  let pb = initProtoBuffer(buffer)
  var record = PeerRecord()

  ? pb.getRequiredField(1, record.peerId)
  ? pb.getRequiredField(2, record.seqNo)

  var addressInfos: seq[seq[byte]]
  if ? pb.getRepeatedField(3, addressInfos):
    for address in addressInfos:
      var addressInfo = AddressInfo()
      let subProto = initProtoBuffer(address)
      let f = subProto.getField(1, addressInfo.address)
      if f.get(false):
          record.addresses &= addressInfo

    if record.addresses.len == 0:
      return err(ProtoError.RequiredFieldMissing)

  ok(record)

proc encode*(record: PeerRecord): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, record.peerId)
  pb.write(2, record.seqNo)

  for address in record.addresses:
    var addrPb = initProtoBuffer()
    addrPb.write(1, address.address)
    pb.write(3, addrPb)

  pb.finish()
  pb.buffer

proc init*(T: typedesc[PeerRecord],
  peerId: PeerId,
  addresses: seq[MultiAddress],
  seqNo = getTime().toUnix().uint64 # follows the recommended implementation, using unix epoch as seq no.
  ): T =

  PeerRecord(
    peerId: peerId,
    seqNo: seqNo,
    addresses: addresses.mapIt(AddressInfo(address: it))
  )


## Functions related to signed peer records
type SignedPeerRecord* = SignedPayload[PeerRecord]

proc payloadDomain*(T: typedesc[PeerRecord]): string = $multiCodec("libp2p-peer-record")
proc payloadType*(T: typedesc[PeerRecord]): seq[byte] = @[(byte) 0x03, (byte) 0x01]

proc checkValid*(spr: SignedPeerRecord): Result[void, EnvelopeError] =
  if not spr.data.peerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

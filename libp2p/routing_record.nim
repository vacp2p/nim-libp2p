# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

## This module implements Routing Records.

{.push raises: [].}

import std/[sequtils, times, hashes]
import pkg/results
import multiaddress, multicodec, peerid, protobuf/minprotobuf, signed_envelope

export peerid, multiaddress, signed_envelope

#TODO remove PeerRecord as it's redundant with ExtendedPeerRecord

type
  AddressInfo* = object
    address*: MultiAddress

  ServiceInfo* = object
    id*: string
    data*: seq[byte]

  PeerRecord* = object
    peerId*: PeerId
    seqNo*: uint64
    addresses*: seq[AddressInfo]

  ExtendedPeerRecord* = object
    peerId*: PeerId
    seqNo*: uint64
    addresses*: seq[AddressInfo]
    services*: seq[ServiceInfo]

proc decode*(
    T: typedesc[AddressInfo], buffer: seq[byte]
): Result[AddressInfo, ProtoError] =
  let pb = initProtoBuffer(buffer)
  var addInfo = AddressInfo()

  ?pb.getRequiredField(1, addInfo.address)

  ok(addInfo)

proc decode*(
    T: typedesc[ServiceInfo], buffer: seq[byte]
): Result[ServiceInfo, ProtoError] =
  var pb = initProtoBuffer(buffer)
  var servInf = ServiceInfo()

  ?pb.getRequiredField(1, servInf.id)
  discard ?pb.getField(2, servInf.data)

  ok(servInf)

proc decode*(
    T: typedesc[PeerRecord], buffer: seq[byte]
): Result[PeerRecord, ProtoError] =
  let pb = initProtoBuffer(buffer)
  var record = PeerRecord()

  ?pb.getRequiredField(1, record.peerId)
  ?pb.getRequiredField(2, record.seqNo)

  var addressInfos: seq[seq[byte]]
  if ?pb.getRepeatedField(3, addressInfos):
    for addressBuf in addressInfos:
      let addressInfo = AddressInfo.decode(addressBuf).valueOr:
        continue

      record.addresses &= addressInfo

    if record.addresses.len == 0:
      return err(ProtoError.RequiredFieldMissing)

  ok(record)

proc decode*(
    T: typedesc[ExtendedPeerRecord], buffer: seq[byte]
): Result[ExtendedPeerRecord, ProtoError] =
  var pb = initProtoBuffer(buffer)
  var record = ExtendedPeerRecord()

  ?pb.getRequiredField(1, record.peerId)
  ?pb.getRequiredField(2, record.seqNo)

  var addressInfos: seq[seq[byte]]
  if ?pb.getRepeatedField(3, addressInfos):
    for addressBuf in addressInfos:
      let addressInfo = AddressInfo.decode(addressBuf).valueOr:
        continue

      record.addresses &= addressInfo

    if record.addresses.len == 0:
      return err(ProtoError.RequiredFieldMissing)

  var serviceInfos: seq[seq[byte]]
  if ?pb.getRepeatedField(4, serviceInfos):
    for serviceBuf in serviceInfos:
      record.services &= ?ServiceInfo.decode(serviceBuf)

  ok(record)

proc encode*(addrInfo: AddressInfo): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, addrInfo.address)

  pb.finish()
  pb.buffer

proc encode*(servInfo: ServiceInfo): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, servInfo.id)

  if servInfo.data.len > 0:
    pb.write(2, servInfo.data)

  pb.finish()
  return pb.buffer

proc encode*(record: PeerRecord): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, record.peerId)
  pb.write(2, record.seqNo)

  for address in record.addresses:
    pb.write(3, address.encode())

  pb.finish()
  pb.buffer

proc encode*(record: ExtendedPeerRecord): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, record.peerId)
  pb.write(2, record.seqNo)

  for address in record.addresses:
    pb.write(3, address.encode())

  for service in record.services:
    pb.write(4, service.encode())

  pb.finish()
  return pb.buffer

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

proc init*(
    T: typedesc[ExtendedPeerRecord],
    peerId: PeerId,
    addresses: seq[MultiAddress],
    seqNo = getTime().toUnix().uint64,
    services: seq[ServiceInfo] = @[],
): T =
  T(
    peerId: peerId,
    seqNo: seqNo,
    addresses: addresses.mapIt(AddressInfo(address: it)),
    services: services,
  )

## Functions related to signed peer records
type SignedPeerRecord* = SignedPayload[PeerRecord]

type SignedExtendedPeerRecord* = SignedPayload[ExtendedPeerRecord]

proc payloadDomain*(T: typedesc[PeerRecord]): string =
  $multiCodec("libp2p-peer-record")

proc payloadType*(T: typedesc[PeerRecord]): seq[byte] =
  @[(byte) 0x03, (byte) 0x01]

proc payloadDomain*(T: typedesc[ExtendedPeerRecord]): string =
  $multiCodec("libp2p-peer-record")

proc payloadType*(T: typedesc[ExtendedPeerRecord]): seq[byte] =
  @[(byte) 0x03, (byte) 0x01]

proc checkValid*(spr: SignedPeerRecord): Result[void, EnvelopeError] =
  if not spr.data.peerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

proc checkValid*(spr: SignedExtendedPeerRecord): Result[void, EnvelopeError] =
  if not spr.data.peerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

# This is for internal use only
proc hash*(service: ServiceInfo): Hash =
  return service.id.hash()

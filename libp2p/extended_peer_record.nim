# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## This module implements Routing Records.

{.push raises: [].}

import std/[sequtils, times, hashes]
import pkg/results
import
  multiaddress,
  multicodec,
  peerid,
  protobuf/minprotobuf,
  signed_envelope,
  routing_record

export peerid, multiaddress, signed_envelope

const
  ## Maximum allowed size (in bytes) for the `data` field inside a `ServiceInfo`.
  ## Larger values are rejected at advertisement creation and on receipt.
  MaxServiceDataSize* = 33

  ## Maximum allowed size (in bytes) for an encoded `SignedExtendedPeerRecord`
  ## (the full XPR advertisement that is stored and gossiped for a service).
  MaxXPRSize* = 1024

type
  ServiceInfo* = object
    id*: string
    data*: seq[byte]

  ExtendedPeerRecord* = object
    peerId*: PeerId
    seqNo*: uint64
    addresses*: seq[AddressInfo]
    services*: seq[ServiceInfo]

proc decode*(
    T: typedesc[ServiceInfo], buffer: sink seq[byte]
): Result[ServiceInfo, ProtoError] =
  var pb = initProtoBuffer(move(buffer))
  var servInf = ServiceInfo()

  ?pb.getRequiredField(1, servInf.id)
  discard ?pb.getField(2, servInf.data)

  ok(servInf)

proc decode*(
    T: typedesc[ExtendedPeerRecord], buffer: sink seq[byte]
): Result[ExtendedPeerRecord, ProtoError] =
  var pb = initProtoBuffer(move(buffer))
  var record = ExtendedPeerRecord()

  ?pb.getRequiredField(1, record.peerId)
  ?pb.getRequiredField(2, record.seqNo)

  var addressInfos: seq[seq[byte]]
  if ?pb.getRepeatedField(3, addressInfos):
    for addressBuf in addressInfos.mitems:
      let addressInfo = AddressInfo.decode(move(addressBuf)).valueOr:
        continue

      record.addresses &= addressInfo

    if record.addresses.len == 0:
      return err(ProtoError.RequiredFieldMissing)

  var serviceInfos: seq[seq[byte]]
  if ?pb.getRepeatedField(4, serviceInfos):
    for serviceBuf in serviceInfos.mitems:
      record.services &= ?ServiceInfo.decode(move(serviceBuf))

  ok(record)

proc encode*(servInfo: ServiceInfo): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, servInfo.id)

  if servInfo.data.len > 0:
    pb.write(2, servInfo.data)

  pb.finish()
  return pb.buffer

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
type SignedExtendedPeerRecord* = SignedPayload[ExtendedPeerRecord]

proc payloadDomain*(T: typedesc[ExtendedPeerRecord]): string =
  $multiCodec("libp2p-peer-record")

proc payloadType*(T: typedesc[ExtendedPeerRecord]): seq[byte] =
  @[(byte) 0x03, (byte) 0x01]

proc checkValid*(spr: SignedExtendedPeerRecord): Result[void, EnvelopeError] =
  if not spr.data.peerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

proc isValid*(si: ServiceInfo): bool =
  si.data.len <= MaxServiceDataSize

proc isValid*(xpr: SignedExtendedPeerRecord): bool =
  for svc in xpr.data.services:
    if not svc.isValid():
      return false
  let encoded = xpr.encode()
  if encoded.isErr or encoded.get().len == 0 or encoded.get().len > MaxXPRSize:
    return false
  true

# This is for internal use only
proc hash*(service: ServiceInfo): Hash =
  return service.id.hash()

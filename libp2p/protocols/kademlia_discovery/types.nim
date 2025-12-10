# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[tables, sequtils, sets, heapqueue, times]
import chronos, chronicles, results, sugar, stew/arrayOps, nimcrypto/sha2
import ../../[peerid, switch, multihash, cid, multicodec, routing_record]
import ../../protobuf/minprotobuf
import ../kademlia/types

const DefaultSelfSPRRereshTime* = 10.minutes

#TODO extend
type LogosPeerRecord* = object
  peerId*: PeerId
  seqNo*: uint64
  addresses*: seq[AddressInfo]

#TODO init a LogosPeerRecord from a PeerInfo
proc init*(T: typedesc[LogosPeerRecord], peerInfo: PeerInfo): T =
  LogosPeerRecord(
    peerId: peerInfo.peerId,
    seqNo: getTime().toUnix().uint64,
    addresses: peerInfo.addrs.mapIt(AddressInfo(address: it)),
  )

proc decode*(
    T: typedesc[LogosPeerRecord], buffer: seq[byte]
): Result[LogosPeerRecord, ProtoError] =
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

  ok(record)

proc encode*(record: LogosPeerRecord): seq[byte] =
  var pb = initProtoBuffer()

  pb.write(1, record.peerId)
  pb.write(2, record.seqNo)

  for address in record.addresses:
    var addrPb = initProtoBuffer()
    addrPb.write(1, address.address)
    pb.write(3, addrPb)

  pb.finish()
  pb.buffer

type SignedLogosPeerRecord* = SignedPayload[LogosPeerRecord]

proc payloadDomain*(T: typedesc[LogosPeerRecord]): string =
  $multiCodec("logos-peer-record")

#TODO choose a number
#[ proc payloadType*(T: typedesc[LogosPeerRecord]): seq[byte] =
  @[(byte) 0x03, (byte) 0x01] ]#

proc checkValid*(spr: SignedLogosPeerRecord): Result[void, EnvelopeError] =
  if not spr.data.peerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

type LogosEntryValidator* = ref object of EntryValidator
method isValid*(
    self: LogosEntryValidator, key: Key, record: EntryRecord
): bool {.raises: [], gcsafe.} =
  let spr = SignedPeerRecord.decode(record.value).valueOr:
    return false

  let expectedPeerId = key.toPeerId().valueOr:
    return false

  if spr.data.peerId != expectedPeerId:
    return false

  return true

type LogosEntrySelector* = ref object of EntrySelector
method select*(
    self: LogosEntrySelector, key: Key, records: seq[EntryRecord]
): Result[int, string] {.raises: [], gcsafe.} =
  if records.len == 0:
    return err("No records to choose from")

  var maxSeqNo: uint64 = 0
  var bestIdx: int = -1

  for i, rec in records:
    let spr = SignedPeerRecord.decode(rec.value).valueOr:
      continue

    let seqNo = spr.data.seqNo
    if seqNo > maxSeqNo or bestIdx == -1:
      maxSeqNo = seqNo
      bestIdx = i

  if bestIdx == -1:
    return err("No valid records")

  return ok(bestIdx)

type KademliaDiscovery* = ref object of KadDHT
  selfSignedLoop*: Future[void]

# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[hashes, tables, sequtils, sets, heapqueue, times]
import chronos, chronicles, results, stew/byteutils, nimcrypto/sha2
import ../../[peerid, switch, multihash, cid, multicodec, routing_record]
import ../../protobuf/minprotobuf
import ../kademlia/types

const DefaultSelfSPRRereshTime* = 10.minutes

type
  ServiceInfo* = object
    id*: string
    data*: seq[byte]

  ExtPeerRecord* = object
    peerId*: PeerId
    seqNo*: uint64
    addresses*: seq[AddressInfo]
    services*: seq[ServiceInfo]

  KademliaDiscovery* = ref object of KadDHT
    services*: HashSet[ServiceInfo]
    selfSignedLoop*: Future[void]

# This is for internal use only
proc hash*(service: ServiceInfo): Hash =
  return service.id.hash()

proc toKey*(service: ServiceInfo): Key =
  return MultiHash.digest("sha2-256", service.id.toBytes()).get().toKey()

proc init*(
    T: typedesc[ExtPeerRecord],
    peerInfo: PeerInfo,
    seqNo: uint64 = getTime().toUnix().uint64,
    services: seq[ServiceInfo] = @[],
): T =
  T(
    peerId: peerInfo.peerId,
    seqNo: seqNo,
    addresses: peerInfo.addrs.mapIt(AddressInfo(address: it)),
    services: services,
  )

proc init*(
    T: typedesc[ExtPeerRecord],
    peerId: PeerId,
    addresses: seq[MultiAddress],
    seqNo: uint64 = getTime().toUnix().uint64,
    services: seq[ServiceInfo] = @[],
): T =
  T(
    peerId: peerId,
    seqNo: seqNo,
    addresses: addresses.mapIt(AddressInfo(address: it)),
    services: services,
  )

type SignedExtPeerRecord* = SignedPayload[ExtPeerRecord]

proc payloadDomain*(T: typedesc[ExtPeerRecord]): string =
  $multiCodec("libp2p-peer-record")

proc payloadType*(T: typedesc[ExtPeerRecord]): seq[byte] =
  "/libp2p/logos-routing-record/".toBytes()

proc checkValid*(spr: SignedExtPeerRecord): Result[void, EnvelopeError] =
  if not spr.data.peerId.match(spr.envelope.publicKey):
    err(EnvelopeInvalidSignature)
  else:
    ok()

type ExtEntryValidator* = ref object of EntryValidator
method isValid*(
    self: ExtEntryValidator, key: Key, record: EntryRecord
): bool {.raises: [], gcsafe.} =
  let spr = SignedPeerRecord.decode(record.value).valueOr:
    return false

  let expectedPeerId = key.toPeerId().valueOr:
    return false

  return spr.data.peerId == expectedPeerId

type ExtEntrySelector* = ref object of EntrySelector
method select*(
    self: ExtEntrySelector, key: Key, records: seq[EntryRecord]
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

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[sequtils, sets, times]
import chronos, results, stew/byteutils
import
  ../../[
    peerid, switch, multihash, cid, multicodec, routing_record, extended_peer_record
  ]
import ../../protobuf/minprotobuf
import ../kademlia/types

const
  DefaultSelfSPRRereshTime* = 10.minutes

  ExtendedKademliaDiscoveryCodec* = "/logos/kad/1.0.0"

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
    T: typedesc[ExtendedPeerRecord],
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

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/sets
import chronos, results
import
  ../../[
    peerid, switch, multihash, cid, multicodec, routing_record, extended_peer_record
  ]
import ../../protobuf/minprotobuf
import ../kademlia/types
import ../capability_discovery/types

type KademliaDiscovery* = ref object of KadDHT
  registrar*: Registrar
  advertiser*: Advertiser
  discoverer*: Discoverer
  selfSignedLoop*: Future[void]
  searchTableLoop*: Future[void]
  advertTableLoop*: Future[void]
  advertiseLoop*: Future[void]
  registrarCacheLoop*: Future[void]
  services*: HashSet[ServiceInfo]
  discoConf*: KademliaDiscoveryConfig

export ServiceInfo

type ExtEntryValidator* = ref object of EntryValidator
method isValid*(
    self: ExtEntryValidator, key: Key, record: EntryRecord
): bool {.raises: [], gcsafe.} =
  let spr = SignedExtendedPeerRecord.decode(record.value).valueOr:
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
    let spr = SignedExtendedPeerRecord.decode(rec.value).valueOr:
      continue

    let seqNo = spr.data.seqNo
    if seqNo > maxSeqNo or bestIdx == -1:
      maxSeqNo = seqNo
      bestIdx = i

  if bestIdx == -1:
    return err("No valid records")

  return ok(bestIdx)

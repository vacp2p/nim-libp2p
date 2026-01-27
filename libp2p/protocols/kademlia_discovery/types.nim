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

export multiaddress

const
  Default_K_register* = 3 # max active registrations per bucket
  Default_K_lookup* = 5 # registrars queried per bucket during lookup
  Default_F_lookup* = 30 # stop when we have this many advertisers
  Default_F_return* = 10 # max ads returned by a single registrar
  Default_E* = 900.0 # advertisement expiry
  Default_C* = 1_000.0 # advertisement cache capacity
  Default_P_occ* = 10.0 # occupancy exponent
  Default_G* = 1e-7 # safety parameter
  Default_Delta* = chronos.seconds(1) # registration window
  Default_M_buckets* = 16 # number of buckets in AdvT/DiscT/RegT

  DefaultSelfSPRRereshTime* = chronos.minutes(10)

  ExtendedKademliaDiscoveryCodec* = "/logos/kad/1.0.0"

type
  RegistrationStatus* = enum
    Confirmed = 0
    Rejected = 1
    Wait = 2

  ServiceId* = Key

  Advertisement* = object
    serviceId*: ServiceId
    peerId*: PeerId
    addrs*: seq[MultiAddress]
    signature*: seq[byte]
    metadata*: seq[byte]
    timestamp*: int64

  Ticket* = object
    ad*: Advertisement
    t_init*: int64
    t_mod*: int64
    t_wait_for*: uint32
    signature*: seq[byte]

  IpTreeNode* = ref object
    counter*: int
    left*, right*: IpTreeNode

  IpTree* = ref object
    root*: IpTreeNode

  Registrar* = ref object
    cache*: OrderedTable[ServiceId, seq[Advertisement]] # service Id → list of ads
    cacheTimestamps*: Table[Advertisement, int64] # ad → insertion time
    ipTree*: IpTree

  AdvertiseTable* = RoutingTable

  Advertiser* = ref object
    advTable*: Table[ServiceId, AdvertiseTable]
    ongoing*: Table[ServiceId, OrderedTable[int, seq[PeerId]]]
      # bucket → active registrars

  SearchTable* = RoutingTable

  Discoverer* = ref object
    discTable*: Table[ServiceId, SearchTable]

  KademliaDiscoveryConfig* = object
    kRegister*: int
    kLookup*: int
    fLookup*: int
    fReturn*: int
    advertExpiry*: float64
    advertCacheCap*: float64
    occupancyExp*: float64
    safetyParam*: float64
    registerationWindow*: chronos.Duration
    bucketsCount*: int
    signedRecordRefreshInterval*: chronos.Duration

  KademliaDiscovery* = ref object of KadDHT
    registrar*: Registrar
    advertiser*: Advertiser
    discoverer*: Discoverer

    selfSignedLoop*: Future[void]
    discovererLoop*: Future[void]
    advertiserLoop*: Future[void]

    services*: HashSet[ServiceInfo]

    discoConf*: KademliaDiscoveryConfig

proc new*(
    T: typedesc[KademliaDiscoveryConfig],
    kRegister = Default_K_register,
    kLookup = Default_K_lookup,
    fLookup = Default_F_lookup,
    fReturn = Default_F_return,
    advertExpiry = Default_E,
    advertCacheCap = Default_C,
    occupancyExp = Default_P_occ,
    safetyParam = Default_G,
    registerationWindow = Default_Delta,
    bucketsCount = Default_M_buckets,
    signedRecordRefreshInterval = DefaultSelfSPRRereshTime,
): T {.raises: [].} =
  KademliaDiscoveryConfig(
    kRegister: kRegister,
    kLookup: kLookup,
    fLookup: fLookup,
    fReturn: fReturn,
    advertExpiry: advertExpiry,
    advertCacheCap: advertCacheCap,
    occupancyExp: occupancyExp,
    safetyParam: safetyParam,
    registerationWindow: registerationWindow,
    bucketsCount: bucketsCount,
    signedRecordRefreshInterval: signedRecordRefreshInterval,
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

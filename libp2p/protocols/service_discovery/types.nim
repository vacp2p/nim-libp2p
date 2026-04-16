# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets, times, tables, hashes]
import chronos, results, stew/byteutils
import nimcrypto/sha2
import
  ../../[
    peerid, switch, multihash, cid, multicodec, routing_record, extended_peer_record
  ]
import ../../protobuf/minprotobuf
import ../../utils/iptree
import ../kademlia/types

const
  DefaultSelfSPRRereshTime* = 10.minutes

  ExtendedServiceDiscoveryCodec* = "/logos/service-discovery/1.0.0"

  Default_K_register* = 3
  Default_K_lookup* = 5
  Default_F_lookup* = 30
  Default_F_return* = 10
  Default_E* = 900.0
  Default_C*: uint64 = 1_000
  Default_P_occ* = chronos.seconds(10)
  Default_G* = 1e-7
  Default_Delta* = chronos.seconds(1)
  Default_M_buckets* = 16

type
  ServiceId* = Key

  ServiceStatus* = enum
    Interest = 0
    Provided = 1
    Both = 2

  ServiceRoutingTableManager* = ref object
    tables*: Table[ServiceId, RoutingTable]
    serviceStatus*: Table[ServiceId, ServiceStatus]

  AdvertisementKey* = tuple[peerId: PeerId, seqNo: uint64]

  Advertisement* = SignedExtendedPeerRecord

  Registrar* = ref object
    cache*: OrderedTable[ServiceId, seq[Advertisement]]
    cacheTimestamps*: Table[AdvertisementKey, uint64]
    ipTree*: IpTree
    boundService*: Table[ServiceId, float64]
    timestampService*: Table[ServiceId, uint64]
    boundIp*: Table[string, float64]
    timestampIp*: Table[string, uint64]

  AdvertiseTask* = ref object
    fut*: Future[void]
    serviceId*: ServiceId

  Advertiser* = ref object
    running*: HashSet[AdvertiseTask]

  ServiceDiscoveryConfig* = object
    kRegister*: int
    kLookup*: int
    fLookup*: int
    fReturn*: int
    advertExpiry*: chronos.Duration
    advertCacheCap*: uint64
    occupancyExp*: chronos.Duration
    safetyParam*: float64
    registrationWindow*: chronos.Duration
    bucketsCount*: int

  ServiceDiscovery* = ref object of KadDHT
    registrar*: Registrar
    rtManager*: ServiceRoutingTableManager
    services*: HashSet[ServiceInfo]
    discoConfig*: ServiceDiscoveryConfig
      # can't use name "config", clashes with KadDHT's config
    xprPublishing*: bool
    selfSignedPeerRecordLoop*: Future[void]

proc new*(
    T: typedesc[ServiceDiscoveryConfig],
    kRegister = Default_K_register,
    kLookup = Default_K_lookup,
    fLookup = Default_F_lookup,
    fReturn = Default_F_return,
    advertExpiry: chronos.Duration = chronos.seconds(int(Default_E)),
    advertCacheCap = Default_C,
    occupancyExp = Default_P_occ,
    safetyParam = Default_G,
    registrationWindow = Default_Delta,
    bucketsCount = Default_M_buckets,
): T {.raises: [].} =
  doAssert advertCacheCap > 0, "advertCacheCap must be > 0"
  ServiceDiscoveryConfig(
    kRegister: kRegister,
    kLookup: kLookup,
    fLookup: fLookup,
    fReturn: fReturn,
    advertExpiry: advertExpiry,
    advertCacheCap: advertCacheCap,
    occupancyExp: occupancyExp,
    safetyParam: safetyParam,
    registrationWindow: registrationWindow,
    bucketsCount: bucketsCount,
  )

proc hash*(t: AdvertiseTask): Hash =
  hash(cast[pointer](t))

proc toAdvertisementKey*(ad: Advertisement): AdvertisementKey {.raises: [].} =
  (peerId: ad.data.peerId, seqNo: ad.data.seqNo)

proc hashServiceId*(serviceStr: string): ServiceId =
  let digest = sha256.digest(serviceStr)
  @(digest.data)

proc advertisesService*(ad: Advertisement, serviceId: ServiceId): bool =
  for service in ad.data.services:
    if hashServiceId(service.id) == serviceId:
      return true
  false

proc new*(T: typedesc[Registrar]): T =
  T(
    cache: initOrderedTable[ServiceId, seq[Advertisement]](),
    cacheTimestamps: initTable[AdvertisementKey, uint64](),
    ipTree: IpTree.new(),
    boundService: initTable[ServiceId, float64](),
    timestampService: initTable[ServiceId, uint64](),
    boundIp: initTable[string, float64](),
    timestampIp: initTable[string, uint64](),
  )

proc new*(T: typedesc[Advertiser]): T =
  T(running: initHashSet[AdvertiseTask]())

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

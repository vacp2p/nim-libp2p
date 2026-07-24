# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets, tables, hashes]
import chronicles, chronos, results, stew/byteutils
import nimcrypto/sha2
import
  ../../[
    peerid, switch, multihash, cid, multicodec, routing_record, extended_peer_record
  ]
import ../../utils/iptree
import ../kademlia/[types, protobuf]

export extended_peer_record.MaxServiceDataSize
export extended_peer_record.MaxXPRSize
export extended_peer_record.isValid

const
  DefaultSelfSPRRereshTime* = 10.minutes

  ExtendedServiceDiscoveryCodec* = "/logos/service-discovery/1.0.0"
  ServiceDiscoveryMaxMsgSize* = 4096

  Default_K_register* = 3
  Default_K_lookup* = 5
  Default_F_lookup* = 30
  Default_F_return* = 10
  Default_E* = 900.secs
  Default_C*: uint64 = 1_000
  Default_P_occ* = 10.0
  Default_G* = 1e-7
  Default_Delta* = 1.secs
  Default_M_buckets* = 16
  Default_IpSimCoefficient* = 1.0

type
  ServiceId* = Key

  ServiceStatus* = enum
    Interest = 0
    Provided = 1
    Both = 2

  ServiceRoutingTableManager* = ref object
    tables*: Table[ServiceId, RoutingTable]
    serviceStatus*: Table[ServiceId, ServiceStatus]
    onServiceTableCreated*: proc(serviceId: ServiceId) {.gcsafe, closure, raises: [].}

  Advertisement* = SignedExtendedPeerRecord

  CachedAd* = object
    ad*: Advertisement
    timestamp*: Moment

  AdvertisementCache* = ref object
    byService*: Table[ServiceId, seq[CachedAd]]
    ipTree*: IpTree
    capacity*: uint64

  Registrar* = ref object
    ads*: AdvertisementCache
    boundService*: Table[ServiceId, Moment]
    timestampService*: Table[ServiceId, Moment]
    boundIp*: Table[string, Moment]
    timestampIp*: Table[string, Moment]

  AdvertiseTask* = ref object
    fut*: Future[void]
    serviceId*: ServiceId
    registrar*: PeerId
    bucketIdx*: int

  Advertiser* = ref object
    running*: HashSet[AdvertiseTask]
    seqNo*: uint64
    providedAdverts*: Table[ServiceId, seq[byte]]

  ServiceDiscoveryConfig* = object
    kRegister*: int
    kLookup*: int
    fLookup*: int
    fReturn*: int
    advertExpiry*: Duration
    advertCacheCap*: uint64
    occupancyExp*: float64
    safetyParam*: float64
    ipSimCoefficient*: float64
    registrationWindow*: Duration
    bucketsCount*: int

  ServiceDiscovery* = ref object of KadDHT
    advertiser*: Advertiser
    registrar*: Registrar
    rtManager*: ServiceRoutingTableManager
    services*: HashSet[ServiceInfo]
    discoConfig*: ServiceDiscoveryConfig
      # can't use name "config", clashes with KadDHT's config
    xprPublishing*: bool
    selfSignedPeerRecordLoop*: Future[void]
    pruneExpiredAdsLoop*: Future[void]
    refreshServiceTablesLoop*: Future[void]
    advertiserMaintenanceLoop*: Future[void]
    localRegistrationLoop*: Future[void]
    serviceBootstrapFuts*: seq[Future[void]]
    clientMode*: bool

proc new*(
    T: typedesc[ServiceDiscoveryConfig],
    kRegister = Default_K_register,
    kLookup = Default_K_lookup,
    fLookup = Default_F_lookup,
    fReturn = Default_F_return,
    advertExpiry = Default_E,
    advertCacheCap = Default_C,
    occupancyExp = Default_P_occ,
    safetyParam = Default_G,
    ipSimCoefficient = Default_IpSimCoefficient,
    registrationWindow = Default_Delta,
    bucketsCount = Default_M_buckets,
): T {.raises: [].} =
  doAssert advertCacheCap > 0, "advertCacheCap must be > 0"
  doAssert ipSimCoefficient >= 0.0, "ipSimCoefficient must be >= 0"
  ServiceDiscoveryConfig(
    kRegister: kRegister,
    kLookup: kLookup,
    fLookup: fLookup,
    fReturn: fReturn,
    advertExpiry: advertExpiry,
    advertCacheCap: advertCacheCap,
    occupancyExp: occupancyExp,
    safetyParam: safetyParam,
    ipSimCoefficient: ipSimCoefficient,
    registrationWindow: registrationWindow,
    bucketsCount: bucketsCount,
  )

proc hash*(t: AdvertiseTask): Hash =
  hash(cast[pointer](t))

proc hash*(ad: Advertisement): Hash {.raises: [].} =
  hash(ad.envelope.signature.data)

proc new*(
    T: typedesc[AdvertisementCache], capacity: uint64 = Default_C
): T {.raises: [].} =
  doAssert capacity > 0, "capacity must be > 0"
  T(
    byService: initTable[ServiceId, seq[CachedAd]](),
    ipTree: IpTree.new(),
    capacity: capacity,
  )

proc encode*(ads: seq[Advertisement], fReturn: int): seq[seq[byte]] {.raises: [].} =
  var adBytes: seq[seq[byte]]
  for ad in ads:
    if adBytes.len >= fReturn:
      break
    adBytes.add(ad.encode())
  adBytes

proc hashServiceId*(serviceStr: string): ServiceId =
  let digest = sha256.digest(serviceStr)
  @(digest.data)

proc advertisesService*(ad: Advertisement, serviceId: ServiceId): bool =
  ad.data.services.anyIt(hashServiceId(it.id) == serviceId)

proc new*(T: typedesc[Registrar], advertCacheCap: uint64 = Default_C): T =
  T(
    ads: AdvertisementCache.new(advertCacheCap),
    boundService: initTable[ServiceId, Moment](),
    timestampService: initTable[ServiceId, Moment](),
    boundIp: initTable[string, Moment](),
    timestampIp: initTable[string, Moment](),
  )

proc new*(T: typedesc[Advertiser]): T =
  T(
    running: initHashSet[AdvertiseTask](),
    seqNo: Moment.now().epochSeconds.uint64,
    providedAdverts: initTable[ServiceId, seq[byte]](),
  )

proc toKey*(service: ServiceInfo): Key =
  return MultiHash.digest("sha2-256", service.id.toBytes()).get().toKey()

proc init*(
    T: typedesc[ExtendedPeerRecord],
    peerInfo: PeerInfo,
    seqNo: uint64 = Moment.now().epochSeconds.uint64,
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

proc record*(disco: ServiceDiscovery): Result[SignedExtendedPeerRecord, string] =
  let peerInfo = disco.switch.peerInfo
  let filteredAddresses = disco.config.addressPolicy.filterAddrs(peerInfo.addrs)

  let peerRecord = ExtendedPeerRecord.init(
    peerId = peerInfo.peerId,
    addresses = filteredAddresses,
    seqNo = Moment.now().epochSeconds.uint64,
    services = disco.services.toSeq(),
  )

  SignedExtendedPeerRecord.build(peerInfo.privateKey, peerRecord)

proc toPeerInfos*(peers: seq[Peer]): seq[PeerInfo] =
  var peerInfos: seq[PeerInfo]

  for p in peers:
    let raw = p.id.valueOr:
      continue
    let pid = PeerId.init(raw).valueOr:
      continue

    let peerInfo = PeerInfo(peerId: pid, addrs: p.addrs)

    peerInfos.add(peerInfo)

  return peerInfos

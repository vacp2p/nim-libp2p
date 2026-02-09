# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sequtils]
import chronos
import ../../[peerid, multihash, multiaddress, extended_peer_record]
import ../kademlia/types
import ../kademlia/protobuf
import nimcrypto/sha2

export multiaddress

type ServiceId* = Key

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

  DefaultSelfSPRRefreshTime* = chronos.minutes(10)

  LogosCapabilityDiscoveryCodec* = "/logos/capability-discovery/1.0.0"

  # Deprecated alias for backward compatibility
  ExtendedKademliaDiscoveryCodec* = LogosCapabilityDiscoveryCodec

# Re-export RegistrationStatus from kademlia protobuf for convenience
type
  RegistrationStatus* = protobuf.RegistrationStatus

  AdvertisementKey* = tuple[peerId: PeerId, seqNo: uint64]

  Advertisement* = SignedExtendedPeerRecord

  Ticket* = object
    ad*: seq[byte]
    t_init*: int64
    t_mod*: int64
    t_wait_for*: uint32
    signature*: seq[byte]

  IpTreeNode* = ref object
    counter*: int
    left*, right*: IpTreeNode

  IpTree* = ref object
    root*: IpTreeNode

  RegistrarTable* = RoutingTable

  Registrar* = ref object
    cache*: OrderedTable[ServiceId, seq[Advertisement]] # service Id -> list of ads
    cacheTimestamps*: Table[AdvertisementKey, int64] # ad key -> insertion time
    ipTree*: IpTree
    # Lower bound enforcement state (RFC section: Lower Bound Enforcement)
    boundService*: Table[ServiceId, float64] # bound(service_id_hash)
    timestampService*: Table[ServiceId, int64] # timestamp(service_id_hash)
    boundIp*: Table[string, float64] # bound(IP)
    timestampIp*: Table[string, int64] # timestamp(IP)
    regTable*: Table[ServiceId, RegistrarTable] # Service routing tables

  AdvertiseTable* = RoutingTable

  PendingAction* =
    tuple[
      scheduledTime: Moment,
      serviceId: ServiceId,
      registrar: PeerId,
      bucketIdx: int,
      ticket: Opt[Ticket],
    ]

  Advertiser* = ref object
    advTable*: Table[ServiceId, AdvertiseTable]
    actionQueue*: seq[PendingAction] # Time-ordered queue of pending actions

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
    signedRecordRefreshInterval = DefaultSelfSPRRefreshTime,
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

proc actionCmp*(a, b: PendingAction): int =
  if a.scheduledTime < b.scheduledTime:
    -1
  elif a.scheduledTime > b.scheduledTime:
    1
  else:
    0

# Helper procs for working with Advertisement (SignedExtendedPeerRecord)

proc getPeerId*(ad: Advertisement): PeerId =
  ## Get peer ID from advertisement
  ad.data.peerId

proc getAddresses*(ad: Advertisement): seq[MultiAddress] =
  ## Get addresses from advertisement
  ad.data.addresses.mapIt(it.address)

proc getServices*(ad: Advertisement): seq[ServiceInfo] =
  ## Get services from advertisement
  ad.data.services

proc getSeqNo*(ad: Advertisement): uint64 =
  ## Get sequence number from advertisement
  ad.data.seqNo

proc hashServiceId*(serviceStr: string): ServiceId =
  ## Hash a service string to get ServiceId (Key)
  ## This is SHA-256 of the service string
  let digest = sha256.digest(serviceStr)
  @(digest.data)

proc advertisesService*(ad: Advertisement, serviceId: ServiceId): bool =
  ## Check if advertisement advertises the given service
  ## Matches by hashing each service.id and comparing with serviceId
  for service in ad.data.services:
    let hashed = hashServiceId(service.id)
    if hashed == serviceId:
      return true
  false

proc toAdvertisementKey*(ad: Advertisement): AdvertisementKey =
  ## Create a cache key from an advertisement
  (peerId: ad.data.peerId, seqNo: ad.data.seqNo)

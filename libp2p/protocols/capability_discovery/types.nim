# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sequtils]
import chronos, stew/endians2
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

type
  RegistrationStatus* = protobuf.RegistrationStatus

  AdvertisementKey* = tuple[peerId: PeerId, seqNo: uint64]

  Advertisement* = SignedExtendedPeerRecord

  IpTreeNode* = ref object
    counter*: int
    left*, right*: IpTreeNode

  IpTree* = ref object
    root*: IpTreeNode

  Registrar* = ref object
    cache*: OrderedTable[ServiceId, seq[Advertisement]] # service Id -> list of ads
    cacheTimestamps*: Table[AdvertisementKey, uint64] # ad key -> insertion time
    ipTree*: IpTree
    # Lower bound enforcement state (RFC section: Lower Bound Enforcement)
    boundService*: Table[ServiceId, float64] # bound(service_id_hash)
    timestampService*: Table[ServiceId, uint64] # timestamp(service_id_hash)
    boundIp*: Table[string, float64] # bound(IP)
    timestampIp*: Table[string, uint64] # timestamp(IP)

  PendingAction* =
    tuple[
      scheduledTime: Moment,
      serviceId: ServiceId,
      registrar: PeerId,
      bucketIdx: int,
      ticket: Opt[Ticket],
    ]

  Advertiser* = ref object
    actionQueue*: seq[PendingAction] # Time-ordered queue of pending actions

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

proc toAdvertisementKey*(ad: Advertisement): AdvertisementKey {.raises: [].} =
  ## Create a cache key from an advertisement
  (peerId: ad.data.peerId, seqNo: ad.data.seqNo)

proc sign*(ticket: var Ticket, privateKey: PrivateKey): Result[void, CryptoError] =
  ## Sign the ticket with the given private key.
  ## Signature is over: encoded_ad || t_init || t_mod || t_wait_for
  var sigInput = newSeqOfCap[byte](ticket.advertisement.len + 8 + 8 + 4)
  sigInput.add(ticket.advertisement)
  sigInput.add(toBytesBE(ticket.tInit.uint64).toSeq)
  sigInput.add(toBytesBE(ticket.tMod.uint64).toSeq)
  sigInput.add(toBytesBE(ticket.tWaitFor.uint32).toSeq)

  let sig = ?privateKey.sign(sigInput)
  ticket.signature = sig.getBytes()
  ok()

proc verify*(ticket: Ticket, publicKey: PublicKey): bool =
  ## Verify the ticket signature with the given public key.
  var sigInput = newSeqOfCap[byte](ticket.advertisement.len + 8 + 8 + 4)
  sigInput.add(ticket.advertisement)
  sigInput.add(toBytesBE(ticket.tInit.uint64).toSeq)
  sigInput.add(toBytesBE(ticket.tMod.uint64).toSeq)
  sigInput.add(toBytesBE(ticket.tWaitFor.uint32).toSeq)

  var sig: Signature
  if not sig.init(ticket.signature):
    return false
  sig.verify(sigInput, publicKey)

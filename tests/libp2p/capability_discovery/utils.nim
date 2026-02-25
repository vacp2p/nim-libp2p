# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[times, options, sequtils]
import results, chronos, chronicles
import ../../../libp2p/[peerid, crypto/crypto, switch, builders, extended_peer_record]
import ../../../libp2p/protocols/[kad_disco, kademlia]
import ../../../libp2p/protocols/kademlia_discovery/types
import
  ../../../libp2p/protocols/capability_discovery/
    [types, advertiser, serviceroutingtables]
import ../../tools/crypto

export types, crypto

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

template checkEncodeDecode*(obj: untyped) =
  check obj == decode(typeof(obj), obj.encode()).get()

proc makeNow(): uint64 =
  getTime().toUnix().uint64

proc fillCache(registrar: Registrar, n: int, now: uint64) =
  for i in 0 ..< n:
    let ad = createTestAdvertisement(serviceId = makeServiceId(i.byte))
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now

proc makeTicket(): Ticket =
  Ticket(
    advertisement: @[1'u8, 2, 3, 4],
    tInit: 1_000_000,
    tMod: 2_000_000,
    tWaitFor: 3000,
    signature: @[],
  )

proc signedTicket(privateKey: PrivateKey): Ticket =
  var t = makeTicket()
  let res = t.sign(privateKey)
  doAssert res.isOk(), "sign failed in test helper"
  t

proc peersCount(rt: RoutingTable): int =
  for b in rt.buckets:
    result += b.peers.len

proc mkKey(seed: byte): Key =
  result = newSeq[byte](32)
  for i in 0 ..< 32:
    result[i] = seed

proc emptyMain(sid: ServiceId): RoutingTable =
  RoutingTable.new(
    sid, config = RoutingTableConfig.new(replication = 3, maxBuckets = 16)
  )

proc hasKey*(kad: KademliaDiscovery, key: Key): bool =
  for b in kad.rtable.buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        return true
  return false

proc createSwitch*(): Switch =
  SwitchBuilder
  .new()
  .withRng(rng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .build()

template setupKadSwitch*(
    validator: untyped, selector: untyped, bootstrapNodes: untyped = @[]
): untyped =
  let switch = createSwitch()
  let kad = KademliaDiscovery.new(
    switch,
    bootstrapNodes,
    config = KadDHTConfig.new(
      validator,
      selector,
      timeout = chronos.seconds(1),
      cleanupProvidersInterval = chronos.milliseconds(100),
      providerExpirationInterval = chronos.seconds(1),
      republishProvidedKeysInterval = chronos.milliseconds(50),
    ),
  )

  switch.mount(kad)
  await switch.start()
  (switch, kad)

# Helper to create a random peer ID
proc makePeerId*(): PeerId =
  PeerId.init(PrivateKey.random(rng[]).get()).get()

# Helper to create a service ID
proc makeServiceId*(): ServiceId =
  @[1'u8, 2, 3, 4]

proc makeServiceInfo*(): ServiceInfo =
  ServiceInfo(id: "blabla", data: @[1, 2, 3, 4])

# Helper to create a service ID with a custom first byte
proc makeServiceId*(id: byte): ServiceId =
  @[id, 2'u8, 3, 4]

proc makeServiceInfo*(id: string): ServiceInfo =
  ServiceInfo(id: id, data: @[1, 2, 3, 4])

proc createTestAdvertisement*(
    serviceId: ServiceId = makeServiceId(),
    peerId: PeerId = makePeerId(),
    addrs: seq[MultiAddress] = @[],
): Advertisement =
  # Create a private key for signing
  let privateKey = PrivateKey.random(rng[]).get()
  # Create ExtendedPeerRecord
  let extRecord = ExtendedPeerRecord(
    peerId: peerId,
    seqNo: getTime().toUnix().uint64.uint64,
    addresses: addrs.mapIt(AddressInfo(address: it)),
    services: @[], # Empty services for now
  )
  # Sign and create SignedExtendedPeerRecord
  SignedExtendedPeerRecord.init(privateKey, extRecord).get()

proc createTestRegistrar*(): Registrar =
  Registrar.new()

proc createTestMultiAddress*(ip: string): MultiAddress =
  MultiAddress.init("/ip4/" & ip & "/tcp/9000").get()

# Helper to create a mock KademliaDiscovery for testing
proc createMockDiscovery*(
    discoConf: KademliaDiscoveryConfig =
      KademliaDiscoveryConfig.new(kRegister = 3, bucketsCount = 16)
): KademliaDiscovery =
  let switch = createSwitch()

  let kad = KademliaDiscovery.new(
    switch,
    bootstrapNodes = @[],
    config = KadDHTConfig.new(
      ExtEntryValidator(),
      ExtEntrySelector(),
      timeout = chronos.seconds(1),
      cleanupProvidersInterval = chronos.milliseconds(100),
      providerExpirationInterval = chronos.seconds(1),
      republishProvidedKeysInterval = chronos.milliseconds(50),
    ),
    discoConf = discoConf,
  )

  kad

# Helper to populate routing table with peers
proc populateRoutingTable*(kad: KademliaDiscovery, peers: seq[PeerId]) =
  for peer in peers:
    let key = peer.toKey()
    discard kad.rtable.insert(key)

# Helper to directly populate a SearchTable for testing
proc populateSearchTable*(
    kad: KademliaDiscovery, serviceId: ServiceId, peers: seq[PeerId]
) =
  ## Directly populate a SearchTable for testing without going through addServiceInterest
  if not kad.serviceRoutingTables.hasService(serviceId):
    return
  for peer in peers:
    let key = peer.toKey()
    kad.serviceRoutingTables.insertPeer(serviceId, key)

proc setupKad*(
    validator: EntryValidator,
    selector: EntrySelector,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
): KademliaDiscovery =
  let switch = createSwitch()
  let config = KadDHTConfig.new(
    validator,
    selector,
    timeout = chronos.seconds(1),
    cleanupProvidersInterval = chronos.milliseconds(100),
    providerExpirationInterval = chronos.seconds(1),
    republishProvidedKeysInterval = chronos.milliseconds(50),
  )
  let kad = KademliaDiscovery.new(switch, bootstrapNodes, config)
  switch.mount(kad)
  kad

proc setupKads*(
    count: int,
    validator: EntryValidator,
    selector: EntrySelector,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
): seq[KademliaDiscovery] =
  var kads: seq[KademliaDiscovery]
  for i in 0 ..< count:
    kads.add(setupKad(validator, selector, bootstrapNodes))
  kads

proc connect*(kad1, kad2: KademliaDiscovery) {.async.} =
  discard kad1.rtable.insert(kad2.switch.peerInfo.peerId)
  discard kad2.rtable.insert(kad1.switch.peerInfo.peerId)
  kad1.switch.peerStore[AddressBook][kad2.switch.peerInfo.peerId] =
    kad2.switch.peerInfo.addrs
  kad2.switch.peerStore[AddressBook][kad1.switch.peerInfo.peerId] =
    kad1.switch.peerInfo.addrs

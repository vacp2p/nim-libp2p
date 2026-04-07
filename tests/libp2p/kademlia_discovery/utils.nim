# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[times, options]
import results, chronos, chronicles
import ../../../libp2p/[peerid, crypto/crypto, switch, builders, extended_peer_record]
import ../../../libp2p/protocols/kad_disco
import ../../../libp2p/protocols/kademlia/[types, protobuf, routingtable]
import ../kademlia/utils
import ../../tools/crypto

export kad_disco, types, crypto

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

template checkEncodeDecode*(obj: untyped) =
  check obj == decode(typeof(obj), obj.encode()).get()

proc makeNow*(): uint64 =
  getTime().toUnix().uint64

proc makePeerId*(): PeerId =
  PeerId.init(PrivateKey.random(rng[]).get()).get()

proc makeServiceInfo*(): ServiceInfo =
  ServiceInfo(id: "blabla", data: @[1, 2, 3, 4])

proc makeServiceInfo*(id: string): ServiceInfo =
  ServiceInfo(id: id, data: @[1, 2, 3, 4])

proc makeTicket*(): Ticket =
  Ticket(
    advertisement: @[1'u8, 2, 3, 4],
    tInit: 1_000_000,
    tMod: 2_000_000,
    tWaitFor: 3000,
    signature: @[],
  )

proc createTestMultiAddress*(ip: string): MultiAddress =
  MultiAddress.init("/ip4/" & ip & "/tcp/9000").get()

proc peersCount*(rt: RoutingTable): int =
  for b in rt.buckets:
    result += b.peers.len

proc mkKey*(seed: byte): Key =
  result = newSeq[byte](32)
  for i in 0 ..< 32:
    result[i] = seed

proc emptyMain*(selfId: Key): RoutingTable =
  RoutingTable.new(
    selfId, config = RoutingTableConfig.new(replication = 3, maxBuckets = 16)
  )

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

proc hasKey*(kad: KademliaDiscovery, key: Key): bool =
  for b in kad.rtable.buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        return true
  false

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

proc createTestDisco*(
    fReturn: int = 3, advertExpiry: float64 = -1, safetyParam: float64 = -1
): KademliaDiscovery =
  var conf = KademliaDiscoveryConfig.new(kRegister = 3, bucketsCount = 16)

  conf.fReturn = fReturn

  if advertExpiry >= 0:
    conf.advertExpiry = advertExpiry
  if safetyParam >= 0:
    conf.safetyParam = safetyParam

  result = createMockDiscovery(conf)

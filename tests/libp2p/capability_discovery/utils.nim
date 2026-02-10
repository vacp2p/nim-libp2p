# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[options]
import results, chronos, chronicles
import ../../../libp2p/[peerid, crypto/crypto, switch, builders]
import ../../../libp2p/protocols/[kad_disco, kademlia]
import ../../../libp2p/protocols/kademlia_discovery/types
import
  ../../../libp2p/protocols/capability_discovery/
    [types, advertiser, serviceroutingtables]
import ../../tools/crypto

export types, crypto

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

# ============================================================================
# Test Helpers
# ============================================================================

template checkEncodeDecode*(obj: untyped) =
  check obj == decode(typeof(obj), obj.encode()).get()

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

# Helper to create a service ID with a custom first byte
proc makeServiceId*(id: byte): ServiceId =
  @[id, 2'u8, 3, 4]

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

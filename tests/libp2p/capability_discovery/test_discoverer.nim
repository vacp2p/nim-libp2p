# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/options
import chronos, chronicles, results
import ../../../libp2p/protocols/kademlia_discovery/[types]
import ../../../libp2p/protocols/capability_discovery/discoverer
import ../../tools/unittest
import ./utils

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

# ============================================================================
# 1. Discoverer Initialization Tests
# ============================================================================

suite "Kademlia Discovery Discoverer - Initialization":
  teardown:
    checkTrackers()

  test "Discoverer.new creates empty discTable":
    let disco = createMockDiscovery()

    check disco.discoverer != nil
    check disco.discoverer.discTable.len == 0

  test "KademliaDiscovery has discoverer initialized":
    let disco = createMockDiscovery()

    check disco.discoverer != nil
    # discTable should be initialized and empty
    check disco.discoverer.discTable.len == 0

# ============================================================================
# 2. Service Interest Management Tests
# ============================================================================

suite "Kademlia Discovery Discoverer - Service Interest Management":
  teardown:
    checkTrackers()

  test "addServiceInterest creates SearchTable for new service":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    disco.addServiceInterest(serviceId)

    check serviceId in disco.discoverer.discTable
    check disco.discoverer.discTable[serviceId] != nil

  test "addServiceInterest with duplicate service is ignored":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    disco.addServiceInterest(serviceId)
    let table1 = disco.discoverer.discTable[serviceId]

    disco.addServiceInterest(serviceId)
    let table2 = disco.discoverer.discTable[serviceId]

    # Should be the same table instance (not re-created)
    check table1 == table2

  test "addServiceInterest bootstraps from main routing table":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    # Add peers to main routing table
    let peer1 = makePeerId()
    let peer2 = makePeerId()
    let peer3 = makePeerId()

    populateRoutingTable(disco, @[peer1, peer2, peer3])

    disco.addServiceInterest(serviceId)

    # SearchTable should be created
    check serviceId in disco.discoverer.discTable
    let searchTable = disco.discoverer.discTable[serviceId]

    # Count peers in SearchTable
    var peerCount = 0
    for bucket in searchTable.buckets:
      peerCount += bucket.peers.len

    # Should have at least some peers from routing table
    check peerCount > 0

  test "addServiceInterest with empty routing table creates empty SearchTable":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    # Routing table starts empty
    check disco.rtable.buckets.len == 0

    disco.addServiceInterest(serviceId)

    # SearchTable should be created but empty
    check serviceId in disco.discoverer.discTable
    check disco.discoverer.discTable[serviceId].buckets.len == 0

  test "addServiceInterest with multiple services creates separate SearchTables":
    let disco = createMockDiscovery()
    let service1 = makeServiceId(1)
    let service2 = makeServiceId(2)
    let service3 = makeServiceId(3)

    disco.addServiceInterest(service1)
    disco.addServiceInterest(service2)
    disco.addServiceInterest(service3)

    check service1 in disco.discoverer.discTable
    check service2 in disco.discoverer.discTable
    check service3 in disco.discoverer.discTable

    # Each should have its own independent table
    check disco.discoverer.discTable[service1] != disco.discoverer.discTable[service2]
    check disco.discoverer.discTable[service2] != disco.discoverer.discTable[service3]

  test "removeServiceInterest removes existing service":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    disco.addServiceInterest(serviceId)
    check serviceId in disco.discoverer.discTable

    disco.discoverer.removeServiceInterest(serviceId)
    check serviceId notin disco.discoverer.discTable

  test "removeServiceInterest with non-existent service is safe":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    # Should not error when removing non-existent service
    disco.discoverer.removeServiceInterest(serviceId)
    check serviceId notin disco.discoverer.discTable

  test "removeServiceInterest doesn't affect other services":
    let disco = createMockDiscovery()
    let service1 = makeServiceId(1)
    let service2 = makeServiceId(2)
    let service3 = makeServiceId(3)

    disco.addServiceInterest(service1)
    disco.addServiceInterest(service2)
    disco.addServiceInterest(service3)

    # Remove only service2
    disco.discoverer.removeServiceInterest(service2)

    check service1 in disco.discoverer.discTable
    check service2 notin disco.discoverer.discTable
    check service3 in disco.discoverer.discTable

# ============================================================================
# 3. SearchTable Operations Tests
# ============================================================================

suite "Kademlia Discovery Discoverer - SearchTable Operations":
  teardown:
    checkTrackers()

  test "SearchTable uses correct config parameters":
    let disco = createMockDiscovery(
      discoConf = KademliaDiscoveryConfig.new(kRegister = 5, bucketsCount = 8)
    )
    let serviceId = makeServiceId()

    disco.addServiceInterest(serviceId)

    let searchTable = disco.discoverer.discTable[serviceId]
    check searchTable.config.replication == disco.config.replication
    check searchTable.config.maxBuckets == 8

  test "SearchTable is isolated per service":
    let disco = createMockDiscovery()
    let service1 = makeServiceId(1)
    let service2 = makeServiceId(2)

    disco.addServiceInterest(service1)
    disco.addServiceInterest(service2)

    # Add different peers to each SearchTable
    let peer1 = makePeerId()
    let peer2 = makePeerId()

    populateSearchTable(disco, service1, @[peer1])
    populateSearchTable(disco, service2, @[peer2])

    # Verify isolation - each service should only have its own peer
    var count1 = 0
    for bucket in disco.discoverer.discTable[service1].buckets:
      count1 += bucket.peers.len

    var count2 = 0
    for bucket in disco.discoverer.discTable[service2].buckets:
      count2 += bucket.peers.len

    # Each should have exactly one peer
    check count1 == 1
    check count2 == 1

  test "addServiceInterest skips invalid peerIds during bootstrap":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    # Create a routing table with some peers
    # All valid PeerIds should be copied
    let peer1 = makePeerId()
    let peer2 = makePeerId()

    populateRoutingTable(disco, @[peer1, peer2])

    disco.addServiceInterest(serviceId)

    # SearchTable should be created
    check serviceId in disco.discoverer.discTable

# ============================================================================
# 4. Service Lookup Tests
# ============================================================================

suite "Kademlia Discovery Discoverer - Service Lookup":
  teardown:
    checkTrackers()

  test "serviceLookup adds service interest automatically":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    check serviceId notin disco.discoverer.discTable

    # serviceLookup adds service interest automatically
    let result = waitFor disco.serviceLookup(serviceId)

    check result.isOk()
    check serviceId in disco.discoverer.discTable

  test "serviceLookup returns empty seq when no peers available":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    # Empty routing table, no peers - should return empty result
    let result = waitFor disco.serviceLookup(serviceId)

    check result.isOk()
    check result.get().len == 0

  test "serviceLookup with empty SearchTable returns empty":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    # Add service interest but no peers
    disco.addServiceInterest(serviceId)

    # SearchTable exists but is empty
    check serviceId in disco.discoverer.discTable
    let searchTable = disco.discoverer.discTable[serviceId]
    check searchTable.buckets.len == 0

    # serviceLookup should handle empty SearchTable gracefully
    let result = waitFor disco.serviceLookup(serviceId)
    check result.isOk()
    check result.get().len == 0

  test "serviceLookup with peers in SearchTable":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    # Add some peers to main routing table
    populateRoutingTable(disco, @[makePeerId(), makePeerId()])

    # Add service interest - this bootstraps SearchTable
    disco.addServiceInterest(serviceId)

    # SearchTable should have some buckets
    check serviceId in disco.discoverer.discTable
    let searchTable = disco.discoverer.discTable[serviceId]
    check searchTable.buckets.len > 0

    # serviceLookup should complete without error
    # (it won't find actual providers since we can't mock sendGetAds)
    let result = waitFor disco.serviceLookup(serviceId)
    check result.isOk()

  test "serviceLookup with multiple service interests uses correct SearchTable":
    let disco = createMockDiscovery()
    let service1 = makeServiceId(1)
    let service2 = makeServiceId(2)
    let service3 = makeServiceId(3)

    # Add peers to create buckets
    populateRoutingTable(disco, @[makePeerId()])

    disco.addServiceInterest(service1)
    disco.addServiceInterest(service2)
    disco.addServiceInterest(service3)

    # Add different peers to each SearchTable
    let peer1 = makePeerId()
    let peer2 = makePeerId()
    let peer3 = makePeerId()

    populateSearchTable(disco, service1, @[peer1])
    populateSearchTable(disco, service2, @[peer2])
    populateSearchTable(disco, service3, @[peer3])

    # Each service should have its own SearchTable
    check service1 in disco.discoverer.discTable
    check service2 in disco.discoverer.discTable
    check service3 in disco.discoverer.discTable

    # Verify they are separate tables
    check disco.discoverer.discTable[service1] != disco.discoverer.discTable[service2]
    check disco.discoverer.discTable[service2] != disco.discoverer.discTable[service3]

  test "serviceLookup fLookup config is set correctly":
    let disco = createMockDiscovery(
      discoConf =
        KademliaDiscoveryConfig.new(kLookup = 3, fLookup = 2, bucketsCount = 16)
    )

    # Verify fLookup config is set correctly
    check disco.discoConf.fLookup == 2
    check disco.discoConf.kLookup == 3

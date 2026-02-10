# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/options
import chronos, chronicles, results
import ../../../libp2p/protocols/kademlia_discovery/[types]
import ../../../libp2p/protocols/capability_discovery/[discoverer, serviceroutingtables]
import ../../tools/unittest
import ./utils

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

# ============================================================================
# 1. Discoverer Initialization Tests
# ============================================================================

suite "Kademlia Discovery Discoverer - Initialization":
  teardown:
    checkTrackers()

  test "Discoverer.new creates empty serviceRoutingTables":
    let disco = createMockDiscovery()

    check disco.serviceRoutingTables.count == 0

suite "Kademlia Discovery Discoverer - Service Lookup":
  teardown:
    checkTrackers()

  test "serviceLookup adds service interest automatically":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    check not disco.serviceRoutingTables.hasService(serviceId)

    # serviceLookup adds service interest automatically
    let result = waitFor disco.lookup(serviceId)

    check result.isOk()
    check disco.serviceRoutingTables.hasService(serviceId)

  test "serviceLookup returns empty seq when no peers available":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    # Empty routing table, no peers - should return empty result
    let result = waitFor disco.lookup(serviceId)

    check result.isOk()
    check result.get().len == 0

  test "serviceLookup fLookup config is set correctly":
    let disco = createMockDiscovery(
      discoConf =
        KademliaDiscoveryConfig.new(kLookup = 3, fLookup = 2, bucketsCount = 16)
    )

    # Verify fLookup config is set correctly
    check disco.discoConf.fLookup == 2
    check disco.discoConf.kLookup == 3

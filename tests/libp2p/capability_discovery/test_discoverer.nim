# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/options
import chronos, results
import ../../../libp2p/protocols/kademlia_discovery/[types]
import ../../../libp2p/protocols/capability_discovery/[discoverer, serviceroutingtables]
import ../../tools/unittest
import ./utils

suite "Kademlia Discovery Discoverer - Service Lookup":
  teardown:
    checkTrackers()

  test "serviceLookup adds service interest automatically":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    check not disco.serviceRoutingTables.hasService(serviceId)

    # serviceLookup adds service interest automatically
    let res = waitFor disco.lookup(serviceId)

    check res.isOk()
    check disco.serviceRoutingTables.hasService(serviceId)

  test "serviceLookup returns empty seq when no peers available":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    # Empty routing table, no peers - should return empty result
    let res = waitFor disco.lookup(serviceId)

    check res.isOk()
    check res.get().len == 0

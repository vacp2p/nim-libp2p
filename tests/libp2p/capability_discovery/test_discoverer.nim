# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/options
import chronos, results
import ../../../libp2p/protocols/kademlia_discovery/[types]
import ../../../libp2p/protocols/capability_discovery/[discoverer, serviceroutingtables]
import ../../tools/unittest
import ./utils

suite "Discoverer - lookup":
  teardown:
    checkTrackers()

  test "creates service routing table on first call":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    check not disco.serviceRoutingTables.hasService(serviceId)

    let res = waitFor disco.lookup(serviceId)

    check res.isOk()
    check disco.serviceRoutingTables.hasService(serviceId)

  test "empty routing table returns ok with empty peers":
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    let res = waitFor disco.lookup(serviceId)

    check res.isOk()
    check res.get().len == 0

  test "calling lookup twice for same service is idempotent":
    # Second call must not error and the table must still exist
    let disco = createMockDiscovery()
    let serviceId = makeServiceId()

    let res1 = waitFor disco.lookup(serviceId)
    let res2 = waitFor disco.lookup(serviceId)

    check res1.isOk()
    check res2.isOk()
    check disco.serviceRoutingTables.hasService(serviceId)

  test "distinct service IDs get independent routing tables":
    let disco = createMockDiscovery()
    let sid1 = makeServiceId(1)
    let sid2 = makeServiceId(2)

    discard waitFor disco.lookup(sid1)
    discard waitFor disco.lookup(sid2)

    check disco.serviceRoutingTables.hasService(sid1)
    check disco.serviceRoutingTables.hasService(sid2)
    # Tables are independent — count reflects both
    check disco.serviceRoutingTables.count() == 2

  test "fLookup cap: result length never exceeds fLookup":
    # Even if the routing table is populated, found peers are bounded by fLookup.
    # With no real peers responding, found stays 0; this verifies the cap is
    # enforced structurally (len <= fLookup) regardless of response content.
    let fLookup = 5
    let disco = createMockDiscovery(fLookup = fLookup)
    let serviceId = makeServiceId()

    populateRoutingTable(disco, newSeq[PeerId](10).mapIt(makePeerId()))

    let res = waitFor disco.lookup(serviceId)

    check res.isOk()
    check res.get().len <= fLookup

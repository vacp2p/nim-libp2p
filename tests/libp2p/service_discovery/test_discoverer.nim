# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results
import ../../../libp2p/peerid
import ../../../libp2p/protocols/service_discovery/[discoverer, types]
import ../../tools/unittest
import ./utils

suite "Discoverer - lookup":
  teardown:
    checkTrackers()

  asyncTest "creates service routing table on first call":
    let disco = makeMockDiscovery()
    let serviceId = makeServiceId()

    check not disco.rtManager.hasService(serviceId)

    let res = await disco.lookup(serviceId)

    check res.isOk()
    check disco.rtManager.hasService(serviceId)

  asyncTest "empty routing table returns ok with empty peers":
    let disco = makeMockDiscovery()
    let serviceId = makeServiceId()

    let res = await disco.lookup(serviceId)

    check res.isOk()
    check res.get().len == 0

  asyncTest "calling lookup twice for same service is idempotent":
    let disco = makeMockDiscovery()
    let serviceId = makeServiceId()

    let res1 = await disco.lookup(serviceId)
    let res2 = await disco.lookup(serviceId)

    check res1.isOk()
    check res2.isOk()
    check disco.rtManager.hasService(serviceId)

  asyncTest "distinct service IDs get independent routing tables":
    let disco = makeMockDiscovery()
    let sid1 = makeServiceId(1)
    let sid2 = makeServiceId(2)

    discard await disco.lookup(sid1)
    discard await disco.lookup(sid2)

    check disco.rtManager.hasService(sid1)
    check disco.rtManager.hasService(sid2)
    check disco.rtManager.count() == 2

  asyncTest "kRegister cap: result length never exceeds kRegister":
    let kRegister = 5
    let disco = makeMockDiscovery(
      discoConfig = ServiceDiscoveryConfig.new(kRegister = kRegister, bucketsCount = 16)
    )
    let serviceId = makeServiceId()

    var peers = newSeq[PeerId](kRegister + 2)
    for i in 0 ..< peers.len:
      peers[i] = makePeerId()

    populateSearchTable(disco, serviceId, peers)

    let res = await disco.lookup(serviceId)

    check res.isOk()
    check res.get().len <= kRegister

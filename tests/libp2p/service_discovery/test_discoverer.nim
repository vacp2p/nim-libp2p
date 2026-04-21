# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, std/sequtils
import ../../../libp2p/peerid
import ../../../libp2p/protocols/service_discovery/[discoverer, types]
import ../../tools/[unittest, lifecycle]
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

  asyncTest "fLookup cap: result does not exceed fLookup and is non-empty":
    let fLookup = 2
    let svcName = "cap-test-svc"
    let serviceId = hashServiceId(svcName)

    # Seeker with fLookup = 2; protocol not mounted since it only dials out
    let seeker = makeMockDiscovery(
      discoConfig =
        ServiceDiscoveryConfig.new(kRegister = 3, bucketsCount = 16, fLookup = fLookup)
    )
    # Responders have the protocol mounted so they can answer getAds
    let responders = setupDiscos(3, ExtEntryValidator(), ExtEntrySelector())

    let allNodes = @[seeker] & responders
    await startNodes(allNodes)
    defer:
      await stopNodes(allNodes)

    # Populate each responder's cache and wire addresses into seeker's peerstore.
    # connect() also inserts responders into seeker's main rtable; lookup() seeds
    # the service table from that table via addService(), so no separate
    # populateSearchTable call is needed.
    for r in responders:
      r.registrar.cache[serviceId] = @[
        makeAdvertisement(svcName),
        makeAdvertisement(svcName),
        makeAdvertisement(svcName),
      ]
      await connect(seeker, r)

    let res = await seeker.lookup(serviceId)

    check res.isOk()
    check res.get().len > 0
    check res.get().len <= fLookup

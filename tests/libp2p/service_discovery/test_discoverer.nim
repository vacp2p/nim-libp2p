# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, std/[sequtils, sets, tables]
import
  ../../../libp2p/[
    protocols/service_discovery,
    protocols/service_discovery/discoverer,
    protocols/service_discovery/types,
  ]
import ../../tools/unittest
import ./utils

suite "Discoverer - lookup (one-shot)":
  teardown:
    checkTrackers()

  asyncTest "one-shot lookup does not leave routing table behind":
    let disco = setupServiceDiscoveryNode()
    let serviceId = makeServiceId()

    check not disco.rtManager.hasService(serviceId)

    let res = await disco.lookup(serviceId)

    check res.isOk()
    check not disco.rtManager.hasService(serviceId)

  asyncTest "empty routing table returns ok with empty peers":
    let disco = setupServiceDiscoveryNode()
    let serviceId = makeServiceId()

    let res = await disco.lookup(serviceId)

    check res.isOk()
    check res.get().len == 0

  asyncTest "calling lookup twice for same service is idempotent":
    let disco = setupServiceDiscoveryNode()
    let serviceId = makeServiceId()

    let res1 = await disco.lookup(serviceId)
    let res2 = await disco.lookup(serviceId)

    check res1.isOk()
    check res2.isOk()

  asyncTest "distinct service IDs do not leave routing tables behind":
    let disco = setupServiceDiscoveryNode()
    let sid1 = makeServiceId(1)
    let sid2 = makeServiceId(2)

    discard await disco.lookup(sid1)
    discard await disco.lookup(sid2)

    check not disco.rtManager.hasService(sid1)
    check not disco.rtManager.hasService(sid2)
    check disco.rtManager.count() == 0

  asyncTest "lookup by ServiceInfo hashes to same ServiceId as lookup by string":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo("my-service")

    let res1 = await disco.lookup(service)
    let res2 = await disco.lookup(toServiceId(service))

    check res1.isOk()
    check res2.isOk()

suite "Discoverer - start/stop discovering":
  teardown:
    checkTrackers()

  asyncTest "registers an Interest routing table and spawns background task":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    let added = disco.startDiscovering(service)

    check added
    check disco.rtManager.hasService(toServiceId(service))
    check disco.discoverer.running.anyIt(it.serviceId == toServiceId(service))

    await disco.stopDiscovering(service)

  asyncTest "returns false when called again for the same service":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    discard disco.startDiscovering(service)
    let added = disco.startDiscovering(service)

    check not added

    await disco.stopDiscovering(service)

  asyncTest "distinct services get independent tables":
    let disco = setupServiceDiscoveryNode()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    discard disco.startDiscovering(s1)
    discard disco.startDiscovering(s2)

    check disco.rtManager.hasService(toServiceId(s1))
    check disco.rtManager.hasService(toServiceId(s2))
    check disco.rtManager.count() == 2

    await disco.stopDiscovering(s1)
    await disco.stopDiscovering(s2)

  asyncTest "removes routing table and cancels task on stop":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    check disco.startDiscovering(service)
    await disco.stopDiscovering(service)

    check not disco.rtManager.hasService(toServiceId(service))
    check not disco.discoverer.running.anyIt(it.serviceId == toServiceId(service))

  asyncTest "stop does not affect a different service":
    let disco = setupServiceDiscoveryNode()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    check disco.startDiscovering(s1)
    check disco.startDiscovering(s2)
    await disco.stopDiscovering(s1)

    check not disco.rtManager.hasService(toServiceId(s1))
    check disco.rtManager.hasService(toServiceId(s2))

    await disco.stopDiscovering(s2)

  asyncTest "lookup returns cache when startDiscovering is active":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let sid = toServiceId(service)

    discard disco.startDiscovering(service)

    let res = await disco.lookup(sid)

    check res.isOk()
    check res.get().mapIt(it.toAdvertisementKey) ==
      disco.discoverer.cache.getOrDefault(sid, @[]).mapIt(it.toAdvertisementKey)

    await disco.stopDiscovering(service)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results
import
  ../../../libp2p/[
    protocols/service_discovery,
    protocols/service_discovery/discoverer,
    protocols/service_discovery/types,
  ]
import ../../tools/unittest
import ./utils

suite "Discoverer - lookup":
  teardown:
    checkTrackers()

  asyncTest "creates service routing table on first call":
    let disco = setupServiceDiscoveryNode()
    let serviceId = makeServiceId()

    check not disco.rtManager.hasService(serviceId)

    let res = await disco.lookup(serviceId)

    check res.isOk()
    check disco.rtManager.hasService(serviceId)

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
    check disco.rtManager.hasService(serviceId)

  asyncTest "distinct service IDs get independent routing tables":
    let disco = setupServiceDiscoveryNode()
    let sid1 = makeServiceId(1)
    let sid2 = makeServiceId(2)

    discard await disco.lookup(sid1)
    discard await disco.lookup(sid2)

    check disco.rtManager.hasService(sid1)
    check disco.rtManager.hasService(sid2)
    check disco.rtManager.count() == 2

  asyncTest "lookup by ServiceInfo hashes to same table as lookup by ServiceId":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo("my-service")
    let serviceId = service.id.hashServiceId()

    let res = await disco.lookup(service)

    check res.isOk()
    check disco.rtManager.hasService(serviceId)

suite "Discoverer - register/unregister interest":
  teardown:
    checkTrackers()

  test "registers an Interest routing table":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    let added = disco.registerInterest(service.id)

    check added
    check disco.rtManager.hasService(service.id.hashServiceId())

  test "returns false when called again for the same service":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    discard disco.registerInterest(service.id)
    let added = disco.registerInterest(service.id)

    check not added

  test "distinct services get independent tables":
    let disco = setupServiceDiscoveryNode()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    discard disco.registerInterest(s1.id)
    discard disco.registerInterest(s2.id)

    check disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())
    check disco.rtManager.count() == 2

  test "unregisterInterest removes Interest entry":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    check disco.registerInterest(service.id)
    disco.unregisterInterest(service.id)

    check not disco.rtManager.hasService(service.id.hashServiceId())

  test "unregisterInterest does not affect a different service":
    let disco = setupServiceDiscoveryNode()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    check disco.registerInterest(s1.id)
    check disco.registerInterest(s2.id)
    disco.unregisterInterest(s1.id)

    check not disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())

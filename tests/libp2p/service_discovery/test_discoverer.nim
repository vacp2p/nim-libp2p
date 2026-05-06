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

suite "Discoverer - start/stop discovering":
  teardown:
    checkTrackers()

  test "registers an Interest routing table":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    let added = disco.startDiscovering(service.id)

    check added
    check disco.rtManager.hasService(service.id.hashServiceId())

  test "returns false when called again for the same service":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    discard disco.startDiscovering(service.id)
    let added = disco.startDiscovering(service.id)

    check not added

  test "distinct services get independent tables":
    let disco = setupServiceDiscoveryNode()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    discard disco.startDiscovering(s1.id)
    discard disco.startDiscovering(s2.id)

    check disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())
    check disco.rtManager.count() == 2

  test "removes Interest and returns false when service was tracked":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    check disco.startDiscovering(service.id)
    disco.stopDiscovering(service.id)

    check not disco.rtManager.hasService(service.id.hashServiceId())

  test "stop does not affect a different service":
    let disco = setupServiceDiscoveryNode()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    check disco.startDiscovering(s1.id)
    check disco.startDiscovering(s2.id)
    disco.stopDiscovering(s1.id)

    check not disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())

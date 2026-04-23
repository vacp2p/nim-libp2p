# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results
import ../../../libp2p/[peerid, switch]
import ../../../libp2p/protocols/service_discovery/[discoverer, types]
import ../../tools/[unittest]
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

  asyncTest "lookup by ServiceInfo hashes to same table as lookup by ServiceId":
    let disco = makeMockDiscovery()
    let service = makeServiceInfo("my-service")
    let serviceId = service.id.hashServiceId()

    let res = await disco.lookup(service)

    check res.isOk()
    check disco.rtManager.hasService(serviceId)

suite "Discoverer - startDiscovering":
  teardown:
    checkTrackers()

  test "registers an Interest routing table":
    let disco = makeMockDiscovery()
    let service = makeServiceInfo()

    let wasAlreadyTracked = disco.startDiscovering(service)

    check not wasAlreadyTracked
    check disco.rtManager.hasService(service.id.hashServiceId())

  test "returns true when called again for the same service":
    let disco = makeMockDiscovery()
    let service = makeServiceInfo()

    discard disco.startDiscovering(service)
    let wasAlreadyTracked = disco.startDiscovering(service)

    check wasAlreadyTracked

  test "distinct services get independent tables":
    let disco = makeMockDiscovery()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    discard disco.startDiscovering(s1)
    discard disco.startDiscovering(s2)

    check disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())
    check disco.rtManager.count() == 2

suite "Discoverer - stopDiscovering":
  teardown:
    checkTrackers()

  test "returns true when service was never tracked":
    let disco = makeMockDiscovery()
    let service = makeServiceInfo()

    let notRemoved = disco.stopDiscovering(service)

    check notRemoved

  test "removes Interest and returns false when service was tracked":
    let disco = makeMockDiscovery()
    let service = makeServiceInfo()

    discard disco.startDiscovering(service)
    let notRemoved = disco.stopDiscovering(service)

    check not notRemoved
    check not disco.rtManager.hasService(service.id.hashServiceId())

  test "second stop on same service returns true (already gone)":
    let disco = makeMockDiscovery()
    let service = makeServiceInfo()

    discard disco.startDiscovering(service)
    discard disco.stopDiscovering(service)
    let notRemoved = disco.stopDiscovering(service)

    check notRemoved

  test "stop does not affect a different service":
    let disco = makeMockDiscovery()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    discard disco.startDiscovering(s1)
    discard disco.startDiscovering(s2)
    discard disco.stopDiscovering(s1)

    check not disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())

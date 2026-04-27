# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, tables
import ../../../libp2p/[peerid, switch]
import ../../../libp2p/protocols/service_discovery/[discoverer, advertiser, types]
import ../../../libp2p/protocols/service_discovery
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

  asyncTest "lookup by ServiceInfo hashes to same table as lookup by ServiceId":
    let disco = makeMockDiscovery()
    let service = makeServiceInfo("my-service")
    let serviceId = service.id.hashServiceId()

    let res = await disco.lookup(service)

    check res.isOk()
    check disco.rtManager.hasService(serviceId)

suite "Discoverer - start/stop discovering":
  teardown:
    checkTrackers()

  test "registers an Interest routing table":
    let disco = makeMockDiscovery()
    let service = makeServiceInfo()

    let added = disco.startDiscovering(service.id)

    check added
    check disco.rtManager.hasService(service.id.hashServiceId())

  test "returns false when called again for the same service":
    let disco = makeMockDiscovery()
    let service = makeServiceInfo()

    discard disco.startDiscovering(service.id)
    let added = disco.startDiscovering(service.id)

    check not added

  test "distinct services get independent tables":
    let disco = makeMockDiscovery()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    discard disco.startDiscovering(s1.id)
    discard disco.startDiscovering(s2.id)

    check disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())
    check disco.rtManager.count() == 2

  test "removes Interest and returns false when service was tracked":
    let disco = makeMockDiscovery()
    let service = makeServiceInfo()

    check disco.startDiscovering(service.id)
    disco.stopDiscovering(service.id)

    check not disco.rtManager.hasService(service.id.hashServiceId())

  test "stop does not affect a different service":
    let disco = makeMockDiscovery()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    check disco.startDiscovering(s1.id)
    check disco.startDiscovering(s2.id)
    disco.stopDiscovering(s1.id)

    check not disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())

  asyncTest "startDiscovering sends messages and finds registered peer":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = makeMockDiscovery(conf)
    let advertiserNode = makeMockDiscovery(conf)
    let discovererNode = makeMockDiscovery(conf)
    registrarNode.switch.mount(registrarNode)
    advertiserNode.switch.mount(advertiserNode)
    discovererNode.switch.mount(discovererNode)
    startAndDeferStop(@[registrarNode, advertiserNode, discovererNode])

    await connect(registrarNode, advertiserNode)
    await connect(registrarNode, discovererNode)

    let service = makeServiceInfo("start-disco-e2e-service")
    let serviceId = service.id.hashServiceId()

    advertiserNode.addProvidedService(service)
    checkUntilTimeout:
      registrarNode.registrar.cache.getOrDefault(serviceId, @[]).len == 1

    check discovererNode.startDiscovering(service.id)

    let found = await discovererNode.lookup(service)
    check found.isOk()
    check found.get().len >= 1
    check found.get()[0].data.peerId == advertiserNode.switch.peerInfo.peerId

    discovererNode.stopDiscovering(service.id)
    check not discovererNode.rtManager.hasService(serviceId)

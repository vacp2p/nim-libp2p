# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, std/[sequtils, tables]
import
  ../../../../libp2p/[
    peerid,
    protocols/kademlia/types,
    protocols/service_discovery,
    protocols/service_discovery/advertiser,
    protocols/service_discovery/discoverer,
    protocols/service_discovery/routing_table_manager,
    protocols/service_discovery/types,
    switch,
  ]
import ../../../tools/[lifecycle, unittest, topology]
import ../utils

suite "Service Discovery Component - Advertise Discover":
  teardown:
    checkTrackers()

  asyncTest "addProvidedService registers service, lookup finds it":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode1 = setupServiceDiscoveryNode(discoConfig = conf)
    let registrarNode2 = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode1, registrarNode2, advertiserNode, discovererNode])

    await connect(registrarNode1, advertiserNode)
    await connect(registrarNode2, advertiserNode)
    await connect(registrarNode1, discovererNode)
    await connect(registrarNode2, discovererNode)

    let service = makeServiceInfo("e2e-test-service")
    let serviceId = service.id.hashServiceId()

    advertiserNode.addProvidedService(service)

    checkUntilTimeout:
      (
        registrarNode1.registrar.cache.getOrDefault(serviceId, @[]).len == 1 or
        registrarNode2.registrar.cache.getOrDefault(serviceId, @[]).len == 1
      )

    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len >= 1
    check found.get().anyIt(it.data.peerId == advertiserNode.switch.peerInfo.peerId)

  asyncTest "registerInterest seeds per-service table from main routing table":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    let peerA = setupServiceDiscoveryNode(discoConfig = conf)
    let peerB = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[discovererNode, peerA, peerB])

    await connectHub(discovererNode, @[peerA, peerB])

    let serviceId = "service"
    let serviceHash = serviceId.hashServiceId()
    let peerAKey = peerA.switch.peerInfo.peerId.toKey()
    let peerBKey = peerB.switch.peerInfo.peerId.toKey()

    check:
      discovererNode.rtable.buckets.anyIt(it.peers.anyIt(it.nodeId == peerAKey))
      discovererNode.rtable.buckets.anyIt(it.peers.anyIt(it.nodeId == peerBKey))
      not discovererNode.rtManager.hasService(serviceHash)

    check discovererNode.rtManager.getTable(serviceHash).isNone()

    check discovererNode.registerInterest(serviceId)

    let table = discovererNode.rtManager.getTable(serviceHash)
    check:
      table.isSome()
      table.get().buckets.anyIt(it.peers.anyIt(it.nodeId == peerAKey))
      table.get().buckets.anyIt(it.peers.anyIt(it.nodeId == peerBKey))

    discovererNode.unregisterInterest(serviceId)
    check not discovererNode.rtManager.hasService(serviceHash)

  asyncTest "two advertisers register the same service - both discoverable":
    # Multiple advertisers at the same registrar use overlapping IPs in tests,
    # which would otherwise drive the second admission's wait time above the timeout.
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0, ipSimCoefficient = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserA = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserB = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, advertiserA, advertiserB, discovererNode])

    await connectHub(registrarNode, @[advertiserA, advertiserB, discovererNode])

    let service = makeServiceInfo("shared-service")
    let serviceId = service.id.hashServiceId()

    advertiserA.addProvidedService(service)
    advertiserB.addProvidedService(service)

    checkUntilTimeout:
      registrarNode.registrar.cache.getOrDefault(serviceId, @[]).len == 2

    let found = await discovererNode.lookup(serviceId)
    check:
      found.get().len == 2
      found.get().anyIt(it.data.peerId == advertiserA.switch.peerInfo.peerId)
      found.get().anyIt(it.data.peerId == advertiserB.switch.peerInfo.peerId)

  asyncTest "one advertiser provides two services - both discoverable":
    # TODO: vacp2p/nim-libp2p#2430 service-disco: missing API for multi-service registration
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0, ipSimCoefficient = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, advertiserNode, discovererNode])

    await connectHub(registrarNode, @[advertiserNode, discovererNode])

    let svcA = makeServiceInfo("service-A")
    let svcB = makeServiceInfo("service-B")
    let svcAId = svcA.id.hashServiceId()
    let svcBId = svcB.id.hashServiceId()

    advertiserNode.addProvidedService(svcA)
    advertiserNode.addProvidedService(svcB)

    checkUntilTimeout:
      registrarNode.registrar.cache.getOrDefault(svcAId, @[]).len == 1 and
        registrarNode.registrar.cache.getOrDefault(svcBId, @[]).len == 1

    let foundA = await discovererNode.lookup(svcAId)
    let foundB = await discovererNode.lookup(svcBId)
    check:
      foundA.get().anyIt(it.data.peerId == advertiserNode.switch.peerInfo.peerId)
      foundA.get().len == 1
      foundB.get().anyIt(it.data.peerId == advertiserNode.switch.peerInfo.peerId)
      # TODO: vacp2p/nim-libp2p#2431 service-disco: lookup returns duplicates when multiple queried peers hold the same ad
      foundB.get().len == 2

  asyncTest "advertiser learns closer peers from REGISTER reply":
    # The registrar's REGISTER reply carries closerPeers.
    # The advertiser must add them to the service-specific routing table so
    # subsequent rounds can reach beyond the initially known registrar.
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let otherNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[advertiserNode, registrarNode, otherNode])

    # The registrar already knows the otherNode, the advertiser does not.
    await connect(registrarNode, otherNode)
    await connect(registrarNode, advertiserNode)

    let service = makeServiceInfo("service-A")
    let serviceId = service.id.hashServiceId()

    advertiserNode.addProvidedService(service)

    let otherKey = otherNode.switch.peerInfo.peerId.toKey()
    checkUntilTimeout:
      advertiserNode.rtManager.getTable(serviceId).get().buckets.anyIt(
        it.peers.anyIt(it.nodeId == otherKey)
      )

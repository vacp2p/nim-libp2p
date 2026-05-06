# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, std/[sequtils, tables]
import
  ../../../../libp2p/[
    protocols/service_discovery,
    protocols/service_discovery/advertiser,
    protocols/service_discovery/discoverer,
    protocols/service_discovery/types,
    switch,
  ]
import ../../../tools/[lifecycle, unittest]
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

  asyncTest "startDiscovering sends messages and finds registered peer":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, advertiserNode, discovererNode])

    await connect(registrarNode, advertiserNode)
    await connect(registrarNode, discovererNode)

    let service = makeServiceInfo("start-disco-e2e-service")
    let serviceId = service.id.hashServiceId()

    advertiserNode.addProvidedService(service)
    checkUntilTimeout:
      registrarNode.registrar.cache.getOrDefault(serviceId, @[]).len > 0

    check discovererNode.startDiscovering(service.id)

    let found = await discovererNode.lookup(service)
    check found.isOk()
    check found.get().len > 0
    check found.get()[0].data.peerId == advertiserNode.switch.peerInfo.peerId

    discovererNode.stopDiscovering(service.id)
    check not discovererNode.rtManager.hasService(serviceId)

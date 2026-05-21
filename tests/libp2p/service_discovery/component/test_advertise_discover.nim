# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, std/[sequtils, tables]
import
  ../../../../libp2p/[
    crypto/crypto,
    peerid,
    protocols/kademlia/types,
    protocols/service_discovery,
    protocols/service_discovery/advertiser,
    protocols/service_discovery/discoverer,
    protocols/service_discovery/routing_table_manager,
    protocols/service_discovery/types,
    switch,
  ]
import ../../../tools/[crypto, lifecycle, unittest, topology]
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
      registrarNode1.countAdsInCache(serviceId) == 1 or
        registrarNode2.countAdsInCache(serviceId) == 1

    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len >= 1
    check found.containsPeer(advertiserNode)

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
      block:
        let ads = registrarNode.getAdsInCache(serviceId)
        ads.anyIt(it.data.peerId == advertiserA.switch.peerInfo.peerId) and
          ads.anyIt(it.data.peerId == advertiserB.switch.peerInfo.peerId)

    checkUntilTimeout:
      block:
        let found = await discovererNode.lookup(serviceId)
        found.get().len == 2 and found.containsPeer(advertiserA) and
          found.containsPeer(advertiserB)

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

    checkUntilTimeout:
      registrarNode.countAdsInCache(svcAId) == 1

    advertiserNode.addProvidedService(svcB)

    checkUntilTimeout:
      registrarNode.countAdsInCache(svcBId) == 1

    checkUntilTimeout:
      block:
        let foundA = await discovererNode.lookup(svcAId)
        foundA.get().anyIt(it.data.peerId == advertiserNode.switch.peerInfo.peerId) and
          foundA.get().len == 1
      block:
        let foundB = await discovererNode.lookup(svcBId)
        foundB.get().anyIt(it.data.peerId == advertiserNode.switch.peerInfo.peerId) and
          foundB.get().len == 1
          # Regression for vacp2p/nim-libp2p#2431: this lookup previously returned a duplicate.

  asyncTest "lookup dedups byte-identical adverts but keeps same (peerId, seqNo) variants":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrar1 = setupServiceDiscoveryNode(discoConfig = conf)
    let registrar2 = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrar1, registrar2, discovererNode])

    await connect(registrar1, discovererNode)
    await connect(registrar2, discovererNode)

    let service = makeServiceInfo("service")
    let serviceId = service.id.hashServiceId()

    let key = PrivateKey.random(rng()).get()
    let seqNo = 1234'u64
    let ad1 = makeAdvertisement(
      serviceId = service.id,
      privateKey = key,
      addrs = @[makeMultiAddress("1.2.3.4")],
      seqNo = seqNo,
    )
    let ad2 = makeAdvertisement(
      serviceId = service.id,
      privateKey = key,
      addrs = @[makeMultiAddress("5.6.7.8")],
      seqNo = seqNo,
    )
    check:
      ad1.toAdvertisementKey() == ad2.toAdvertisementKey()
      ad1.envelope.signature.data != ad2.envelope.signature.data

    # ad1 served by both registrars (byte-identical duplicate)
    # ad2 served only by registrar1, sharing (peerId, seqNo) with ad1.
    registrar1.registrar.cache[serviceId] = @[ad1, ad2]
    registrar2.registrar.cache[serviceId] = @[ad1]

    let found = await discovererNode.lookup(serviceId)
    check:
      found.get().len == 2
      found.get().anyIt(it.envelope.signature.data == ad1.envelope.signature.data)
      found.get().anyIt(it.envelope.signature.data == ad2.envelope.signature.data)

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
      advertiserNode.rtManager.getTable(serviceId).get().hasPeer(otherKey)

  asyncTest "advertiser retries with the ticket after Wait and gets Confirmed":
    # First REGISTER gets Wait + ticket, advertiser sleeps then retries
    # with the ticket and the registrar admits the ad. The registration
    # window is widened to 10s so the retry's handshake has time to complete.
    let conf = ServiceDiscoveryConfig.new(registrationWindow = 10.secs)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let service = makeServiceInfo("service")
    let serviceId = service.id.hashServiceId()

    advertiserNode.addProvidedService(service)

    checkUntilTimeout:
      registrarNode.countAdsInCache(serviceId) == 1

    let ads = registrarNode.getAdsInCache(serviceId)
    check ads[0].data.peerId == advertiserNode.switch.peerInfo.peerId

  asyncTest "advertiser re-advertises after advertExpiry":
    let conf = ServiceDiscoveryConfig.new(advertExpiry = 500.millis, safetyParam = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let service = makeServiceInfo("service")
    let serviceId = service.id.hashServiceId()

    # addProvidedService starts an advertiseToRegistrar task.
    # The task keeps running after the first REGISTER is Confirmed.
    # It waits advertExpiry, then sends REGISTER again for the same ad.
    # The registrar keeps one ad and refreshes cacheTimestamps.
    advertiserNode.addProvidedService(service)

    checkUntilTimeout:
      registrarNode.countAdsInCache(serviceId) == 1

    let
      cachedAd = registrarNode.getAdsInCache(serviceId)[0]
      adKey = cachedAd.toAdvertisementKey()
      firstTimestamp = registrarNode.registrar.cacheTimestamps[adKey]

    checkUntilTimeout:
      block:
        let ads = registrarNode.getAdsInCache(serviceId)
        ads.len == 1 and ads[0].toAdvertisementKey() == adKey and
          registrarNode.registrar.cacheTimestamps.hasKey(adKey) and
          registrarNode.registrar.cacheTimestamps[adKey] > firstTimestamp

  asyncTest "advertiser stops after the registrar replies Rejected":
    let registrarNode = setupServiceDiscoveryNode()
    let advertiserNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceId = makeServiceId()

    # Seed the per-service table directly so we skip the bucket-iteration
    # tasks that addProvidedService would start.
    check advertiserNode.rtManager.addService(
      serviceId, advertiserNode.rtable, advertiserNode.config.replication,
      advertiserNode.discoConfig.bucketsCount, Provided,
    )

    # Malformed bytes force a Rejected reply.
    let badAdvert = @[1'u8, 2, 3, 4]

    # The advertiser should hit Rejected, break its retry loop, and return.
    await advertiserNode
      .advertiseToRegistrar(
        serviceId, registrarNode.switch.peerInfo.peerId, Opt.none(Ticket), badAdvert
      )
      .wait(5.seconds)

    check registrarNode.countAdsInCache(serviceId) == 0

  asyncTest "auto-advertise on start":
    # Using ipSimCoefficient = 0.0 to not trigger sybil protection when advertising multiple services
    # TODO: vacp2p/nim-libp2p#2430 service-disco: missing API for multi-service registration
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0, ipSimCoefficient = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)

    startAndDeferStop(@[registrarNode, discovererNode])
    await connect(registrarNode, discovererNode)

    let serviceA = makeServiceInfo("service-A")
    let serviceB = makeServiceInfo("service-B")
    let serviceAId = serviceA.id.hashServiceId()
    let serviceBId = serviceB.id.hashServiceId()

    let advertiserNode = setupServiceDiscoveryNode(
      discoConfig = conf,
      bootstrapNodes =
        @[(registrarNode.switch.peerInfo.peerId, registrarNode.switch.peerInfo.addrs)],
      services = @[serviceA, serviceB],
    )

    startAndDeferStop(@[advertiserNode])

    checkUntilTimeout:
      block:
        let foundA = await discovererNode.lookup(serviceAId)
        let foundB = await discovererNode.lookup(serviceBId)
        foundA.containsPeer(advertiserNode) and foundB.containsPeer(advertiserNode)

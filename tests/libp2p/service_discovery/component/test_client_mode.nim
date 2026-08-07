# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, std/sequtils
import
  ../../../../libp2p/[
    peerinfo,
    protocols/kademlia,
    protocols/service_discovery,
    protocols/service_discovery/advertiser,
    protocols/service_discovery/types,
    switch,
  ]
import ../../../tools/[lifecycle, unittest]
import ../utils

suite "Service Discovery Component - Client Mode":
  teardown:
    checkTrackers()

  asyncTest "client-mode node does not serve REGISTER":
    # The codec stays mounted, because there is no multistream unmount.
    let clientNode = setupServiceDiscoveryNode(client = true)
    let serverNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[clientNode, serverNode])
    await connect(serverNode, clientNode)

    check:
      ExtendedServiceDiscoveryCodec in serverNode.switch.peerInfo.protocols
      ExtendedServiceDiscoveryCodec in clientNode.switch.peerInfo.protocols

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let ad = makeAdvertisement(serviceName).encode().get()
    let response =
      await serverNode.sendRegister(clientNode.switch.peerInfo.peerId, serviceId, ad)
    check:
      response.isErr
      clientNode.registrar.ads.len == 0

  asyncTest "client-mode node returns no ads when targeted by lookup":
    let clientNode = setupServiceDiscoveryNode(client = true)
    let discovererNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[clientNode, discovererNode])
    await connect(discovererNode, clientNode)

    check ExtendedServiceDiscoveryCodec in clientNode.switch.peerInfo.protocols

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    # Seed the client's cache so lookup would find the ad if the client were serving GET_ADS.
    clientNode.registrar.seedAd(serviceId, makeAdvertisement(serviceName))

    let found = await discovererNode.lookup(serviceId)
    check:
      found.get().len == 0

  asyncTest "client-mode node successfully completes lookup against server-mode registrars":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let clientDiscoverer = setupServiceDiscoveryNode(discoConfig = conf, client = true)
    let serverRegistrar = setupServiceDiscoveryNode(discoConfig = conf)
    let serverAdvertiser = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[clientDiscoverer, serverRegistrar, serverAdvertiser])

    await connect(clientDiscoverer, serverRegistrar)
    await connect(serverAdvertiser, serverRegistrar)

    let service = makeServiceInfo("service")
    let serviceId = service.id.hashServiceId()

    check serverAdvertiser.addProvidedService(service).isOk()

    checkUntilTimeout:
      serverRegistrar.countAdsInCache(serviceId) == 1

    let found = await clientDiscoverer.lookup(serviceId)
    check:
      found.get().anyIt(it.data.peerId == serverAdvertiser.switch.peerInfo.peerId)

  asyncTest "client-mode node rejects addProvidedService":
    let clientNode = setupServiceDiscoveryNode(client = true)
    startAndDeferStop(@[clientNode])

    let service = makeServiceInfo("service")

    check clientNode.addProvidedService(service).isErr()
    check not clientNode.rtManager.hasService(service.id.hashServiceId())

  asyncTest "a downgrade to client mode stops new advertising":
    let advertiserNode = setupServiceDiscoveryNode()
    let registrarNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[advertiserNode, registrarNode])
    await connect(advertiserNode, registrarNode)

    let service = makeServiceInfo("service")
    let serviceId = service.id.hashServiceId()

    check advertiserNode.addProvidedService(service).isOk()
    checkUntilTimeout:
      registrarNode.countAdsInCache(serviceId) == 1

    check await advertiserNode.changeMode(isServer = false)

    let other = makeServiceInfo("other-service")
    check advertiserNode.addProvidedService(other).isErr()
    check registrarNode.countAdsInCache(other.id.hashServiceId()) == 0

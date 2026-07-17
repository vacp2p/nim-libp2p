# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, std/sequtils
import
  ../../../../libp2p/[
    peerinfo,
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

  asyncTest "client-mode node does not advertise the service-discovery codec":
    # Client mode is consumer-only, it doesn't serve REGISTER.
    let clientNode = setupServiceDiscoveryNode(client = true)
    let serverNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[clientNode, serverNode])
    await connect(serverNode, clientNode)

    check:
      ExtendedServiceDiscoveryCodec in serverNode.switch.peerInfo.protocols
      ExtendedServiceDiscoveryCodec notin clientNode.switch.peerInfo.protocols

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

    check ExtendedServiceDiscoveryCodec notin clientNode.switch.peerInfo.protocols

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

    serverAdvertiser.addProvidedService(service)

    checkUntilTimeout:
      serverRegistrar.countAdsInCache(serviceId) == 1

    let found = await clientDiscoverer.lookup(serviceId)
    check:
      found.get().anyIt(it.data.peerId == serverAdvertiser.switch.peerInfo.peerId)

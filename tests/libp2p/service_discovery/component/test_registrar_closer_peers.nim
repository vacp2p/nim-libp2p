# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, sequtils
import
  ../../../../libp2p/[
    peerid,
    protocols/kademlia/types,
    protocols/service_discovery/advertiser,
    protocols/service_discovery/discoverer,
    protocols/service_discovery/routing_table_manager,
    protocols/service_discovery/types,
    switch,
  ]
import ../../../../libp2p/protocols/kademlia/protobuf as kad_protobuf
import ../../../tools/[lifecycle, unittest]
import ../utils

suite "Service Discovery Component - Registrar Closer Peers":
  teardown:
    checkTrackers()

  asyncTest "REGISTER closerPeers come from RegT when available":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    let serviceOnlyNode = setupServiceDiscoveryNode(discoConfig = conf)
    let kadOnlyNode = setupServiceDiscoveryNode(discoConfig = conf)

    startAndDeferStop(@[registrarNode, advertiserNode, serviceOnlyNode, kadOnlyNode])
    await connect(registrarNode, advertiserNode)
    await connect(registrarNode, kadOnlyNode)

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()

    # serviceOnlyNode has addresses in the peer store but is not in the main Kad table.
    # Insert it into RegT only.
    registrarNode.switch.peerStore[AddressBook][serviceOnlyNode.switch.peerInfo.peerId] =
      serviceOnlyNode.switch.peerInfo.addrs

    discard registrarNode.rtManager.addService(
      serviceId, registrarNode.rtable, registrarNode.config.replication,
      conf.bucketsCount, Interest,
    )
    registrarNode.rtManager.insertPeer(
      serviceId, serviceOnlyNode.switch.peerInfo.peerId.toKey()
    )

    let adBytes = makeAdvertisement(serviceName).encode().get()
    let response = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )

    check response.isOk()
    let closerPeerIds = response.get().closerPeers.mapIt(it.peerId)

    check:
      serviceOnlyNode.switch.peerInfo.peerId in closerPeerIds
      kadOnlyNode.switch.peerInfo.peerId in closerPeerIds

  asyncTest "GET_ADS closerPeers come from RegT when available":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    let serviceOnlyNode = setupServiceDiscoveryNode(discoConfig = conf)
    let kadOnlyNode = setupServiceDiscoveryNode(discoConfig = conf)

    startAndDeferStop(@[registrarNode, discovererNode, serviceOnlyNode, kadOnlyNode])
    await connect(registrarNode, discovererNode)
    await connect(registrarNode, kadOnlyNode)

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()

    # serviceOnlyNode has addresses in the peer store but is not in the main Kad table.
    # Insert it into RegT only.

    registrarNode.switch.peerStore[AddressBook][serviceOnlyNode.switch.peerInfo.peerId] =
      serviceOnlyNode.switch.peerInfo.addrs

    discard registrarNode.rtManager.addService(
      serviceId, registrarNode.rtable, registrarNode.config.replication,
      conf.bucketsCount, Interest,
    )
    registrarNode.rtManager.insertPeer(
      serviceId, serviceOnlyNode.switch.peerInfo.peerId.toKey()
    )

    let serviceOnlyKey = serviceOnlyNode.switch.peerInfo.peerId.toKey()

    check:
      not discovererNode.rtable.hasPeer(serviceOnlyKey)

    let found = await discovererNode.lookup(serviceId)
    check:
      found.isOk()
      discovererNode.rtable.hasPeer(serviceOnlyKey)

  asyncTest "REGISTER with Wait adds advertiser to RegT":
    # Use safetyParam = 0 so the first registration is Confirmed, and
    # advertCacheCap = 1 so the cache is full after that, forcing the
    # second registration to return Wait.
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0, advertCacheCap = 1)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let confirmedNode = setupServiceDiscoveryNode(discoConfig = conf)
    let waitNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, confirmedNode, waitNode])
    await connect(registrarNode, confirmedNode)

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()

    let confirmedAdBytes = makeAdvertisement(
        serviceName, confirmedNode.switch.peerInfo.privateKey
      )
      .encode()
      .get()
    let confirmedResponse = await confirmedNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, confirmedAdBytes
    )
    check:
      confirmedResponse.isOk()
      confirmedResponse.get().status == kad_protobuf.RegistrationStatus.Confirmed

    let confirmedKey = confirmedNode.switch.peerInfo.peerId.toKey()
    let tableAfterConfirmed = registrarNode.rtManager.getTable(serviceId)
    check:
      tableAfterConfirmed.isSome()
      tableAfterConfirmed.get().hasPeer(confirmedKey)

    # Connect waitNode after the service table is created so it is not
    # seeded into it from the main Kad table.
    await connect(registrarNode, waitNode)

    let waitKey = waitNode.switch.peerInfo.peerId.toKey()
    check not tableAfterConfirmed.get().hasPeer(waitKey)

    # The cache is full so the registrar returns Wait.
    let waitAdBytes =
      makeAdvertisement(serviceName, waitNode.switch.peerInfo.privateKey).encode().get()
    let waitResponse = await waitNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, waitAdBytes
    )
    check:
      waitResponse.isOk()
      waitResponse.get().status == kad_protobuf.RegistrationStatus.Wait

    let tableAfterWait = registrarNode.rtManager.getTable(serviceId)
    check:
      tableAfterWait.isSome()
      tableAfterWait.get().hasPeer(waitKey)

  asyncTest "GET_ADS adds discoverer to RegT":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, advertiserNode, discovererNode])
    await connect(registrarNode, advertiserNode)

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let adBytes = makeAdvertisement(
        serviceName, advertiserNode.switch.peerInfo.privateKey
      )
      .encode()
      .get()

    # Create RegT via a Confirmed registration before the discoverer is
    # connected, so the discoverer is not seeded into it.
    let response = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check response.isOk()
    check response.get().status == kad_protobuf.RegistrationStatus.Confirmed

    await connect(registrarNode, discovererNode)

    let discovererKey = discovererNode.switch.peerInfo.peerId.toKey()
    let tableBefore = registrarNode.rtManager.getTable(serviceId)
    check:
      tableBefore.isSome()
      not tableBefore.get().hasPeer(discovererKey)

    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len == 1

    let tableAfter = registrarNode.rtManager.getTable(serviceId)
    check:
      tableAfter.isSome()
      tableAfter.get().hasPeer(discovererKey)

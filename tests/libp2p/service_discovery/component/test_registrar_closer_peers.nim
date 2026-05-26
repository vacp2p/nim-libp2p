# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, sequtils
import
  ../../../../libp2p/[
    crypto/crypto,
    multiaddress,
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

# TODO: nim-libp2p#2526 service-disco: registrar closerPeers do not use RegT

suite "Service Discovery Component - Registrar Closer Peers":
  teardown:
    checkTrackers()

  asyncTest "REGISTER closerPeers come from main Kad table, not RegT":
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
      kadOnlyNode.switch.peerInfo.peerId in closerPeerIds
      serviceOnlyNode.switch.peerInfo.peerId notin closerPeerIds
        # node is in RegT with valid addresses, but RegT is not used.

  asyncTest "GET_ADS closerPeers come from main Kad table, not RegT":
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

    let kadOnlyKey = kadOnlyNode.switch.peerInfo.peerId.toKey()
    let serviceOnlyKey = serviceOnlyNode.switch.peerInfo.peerId.toKey()

    check:
      not discovererNode.rtable.hasPeer(kadOnlyKey)
      not discovererNode.rtable.hasPeer(serviceOnlyKey)

    let found = await discovererNode.lookup(serviceId)
    check:
      found.isOk()
      discovererNode.rtable.hasPeer(kadOnlyKey)
      not discovererNode.rtable.hasPeer(serviceOnlyKey)
        # node is in RegT with valid addresses, but RegT is not used.

  asyncTest "REGISTER with Wait does not add advertiser to RegT":
    let registrarNode = setupServiceDiscoveryNode()
    let advertiserNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceName = "wait-no-insert"
    let serviceId = serviceName.hashServiceId()
    let adBytes = makeAdvertisement(
        serviceName, advertiserNode.switch.peerInfo.privateKey
      )
      .encode()
      .get()

    let response = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check response.isOk()
    check response.get().status == kad_protobuf.RegistrationStatus.Wait

    # Spec: the registrar adds the advertiser to RegT on every REGISTER.
    # Implementation: RegT is not created until Confirmed.
    let advertiserKey = advertiserNode.switch.peerInfo.peerId.toKey()
    let serviceTable = registrarNode.rtManager.getTable(serviceId)
    if serviceTable.isSome():
      check not serviceTable.get().hasPeer(advertiserKey)
    else:
      # RegT not created at all — confirms the divergence.
      check true

  asyncTest "REGISTER with Confirmed is the only path that writes to RegT":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceName = "confirmed-insert"
    let serviceId = serviceName.hashServiceId()
    let adBytes = makeAdvertisement(
        serviceName, advertiserNode.switch.peerInfo.privateKey
      )
      .encode()
      .get()

    let response = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check response.isOk()
    check response.get().status == kad_protobuf.RegistrationStatus.Confirmed

    let advertiserKey = advertiserNode.switch.peerInfo.peerId.toKey()
    let serviceTable = registrarNode.rtManager.getTable(serviceId)
    check serviceTable.isSome()
    check serviceTable.get().hasPeer(advertiserKey)

  asyncTest "GET_ADS does not add discoverer to RegT":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, advertiserNode, discovererNode])
    await connect(registrarNode, advertiserNode)

    let serviceName = "get-ads-no-disco-insert"
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
    check tableBefore.isSome()
    check not tableBefore.get().hasPeer(discovererKey)

    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len == 1

    # Spec: the registrar adds the discoverer to RegT on GET_ADS.
    # Implementation: GET_ADS never writes to RegT.
    let tableAfter = registrarNode.rtManager.getTable(serviceId)
    check tableAfter.isSome()
    check not tableAfter.get().hasPeer(discovererKey)

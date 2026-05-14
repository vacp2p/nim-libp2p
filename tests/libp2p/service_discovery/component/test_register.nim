# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results
import
  ../../../../libp2p/[
    protocols/service_discovery/advertiser,
    protocols/service_discovery/types,
    switch,
  ]
import ../../../../libp2p/protocols/kademlia/protobuf as kad_protobuf
import ../../../tools/[lifecycle, unittest]
import ../utils

suite "Service Discovery Component - Register":
  teardown:
    checkTrackers()

  asyncTest "first REGISTER with no ticket returns Wait":
    let registrarNode = setupServiceDiscoveryNode()
    let advertiserNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceName = "test-register-service"
    let serviceId = serviceName.hashServiceId()
    let adBytes = makeAdvertisement(serviceName).encode().get()

    let regResp = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check regResp.isOk()
    check regResp.get().status == kad_protobuf.RegistrationStatus.Wait
    check regResp.get().ticket.isSome()

  asyncTest "REGISTER with out-of-window ticket ignores ticket and returns Wait":
    let registrarNode = setupServiceDiscoveryNode()
    let advertiserNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceName = "out-of-window-service"
    let serviceId = serviceName.hashServiceId()
    let adBytes = makeAdvertisement(
        serviceName, advertiserNode.switch.peerInfo.privateKey
      )
      .encode()
      .get()
    let registrarKey = registrarNode.switch.peerInfo.privateKey
    let now = Moment.now()
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: now - 10000000.secs,
      tMod: now - 10000000.secs,
      tWaitFor: 0.secs,
      signature: @[],
    )
    check ticket.sign(registrarKey).isOk()

    let regResp = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes, Opt.some(ticket)
    )
    check regResp.isOk()
    check regResp.get().status == kad_protobuf.RegistrationStatus.Wait

  asyncTest "REGISTER with safetyParam=0 returns Confirmed on first attempt":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceName = "test-confirm-service"
    let serviceId = serviceName.hashServiceId()
    let adBytes = makeAdvertisement(serviceName).encode().get()

    let regResp = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check regResp.isOk()
    check regResp.get().status == kad_protobuf.RegistrationStatus.Confirmed

  asyncTest "REGISTER preserves registrar cache seqNo semantics":
    # Use a non-zero subsecond expiry: the waiting-time formula rounds it down
    # to zero seconds, while registrar maintenance still has a real interval.
    let conf = ServiceDiscoveryConfig.new(advertExpiry = 999.millis)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)

    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let registrarPeerId = registrarNode.switch.peerInfo.peerId
    let advertiserKey = advertiserNode.switch.peerInfo.privateKey
    let addrA = makeMultiAddress("10.0.0.1")
    let addrB = makeMultiAddress("10.0.0.2")
    let addrC = makeMultiAddress("10.0.0.3")

    let originalAd =
      makeAdvertisement(serviceName, advertiserKey, addrs = @[addrA], seqNo = 1)
    let duplicateSameSeqAd =
      makeAdvertisement(serviceName, advertiserKey, addrs = @[addrB], seqNo = 1)
    let newerSeqAd =
      makeAdvertisement(serviceName, advertiserKey, addrs = @[addrB], seqNo = 2)
    let staleLowerSeqAd =
      makeAdvertisement(serviceName, advertiserKey, addrs = @[addrC], seqNo = 1)

    # First REGISTER stores the advertiser's initial seqNo/address pair.
    var registerResponse = await advertiserNode.sendRegister(
      registrarPeerId, serviceId, originalAd.encode().get()
    )
    check registerResponse.get().status == kad_protobuf.RegistrationStatus.Confirmed

    var cachedAd = registrarNode.getAdsInCache(serviceId)[0]
    check:
      cachedAd.data.seqNo == 1
      cachedAd.data.addresses[0].address == addrA

    # Same peer and same seqNo is a duplicate, even if the payload differs.
    # The registrar must keep the exact original advertisement.
    registerResponse = await advertiserNode.sendRegister(
      registrarPeerId, serviceId, duplicateSameSeqAd.encode().get()
    )
    check registerResponse.get().status == kad_protobuf.RegistrationStatus.Confirmed

    cachedAd = registrarNode.getAdsInCache(serviceId)[0]
    check:
      cachedAd.envelope.signature.data == originalAd.envelope.signature.data
      cachedAd.data.seqNo == 1
      cachedAd.data.addresses[0].address == addrA

    # Same peer with a higher seqNo is newer state, so it replaces the cache.
    registerResponse = await advertiserNode.sendRegister(
      registrarPeerId, serviceId, newerSeqAd.encode().get()
    )
    check registerResponse.get().status == kad_protobuf.RegistrationStatus.Confirmed

    cachedAd = registrarNode.getAdsInCache(serviceId)[0]
    check:
      cachedAd.data.seqNo == 2
      cachedAd.data.addresses[0].address == addrB

    # Same peer with a lower seqNo is stale and must not replace newer state.
    registerResponse = await advertiserNode.sendRegister(
      registrarPeerId, serviceId, staleLowerSeqAd.encode().get()
    )
    check registerResponse.get().status == kad_protobuf.RegistrationStatus.Confirmed

    cachedAd = registrarNode.getAdsInCache(serviceId)[0]
    check:
      cachedAd.data.seqNo == 2
      cachedAd.data.addresses[0].address == addrB
 
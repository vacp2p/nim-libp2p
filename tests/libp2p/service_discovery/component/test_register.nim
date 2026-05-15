# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results
import
  ../../../../libp2p/
    [protocols/service_discovery/advertiser, protocols/service_discovery/types, switch]
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

  asyncTest "back-to-back REGISTERs return identical waits":
    # Anti-grinding: tMod + tWaitFor (eligibility moment) must never move earlier across retries.
    let registrarNode = setupServiceDiscoveryNode()
    let advertiserNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let adBytes = makeAdvertisement(
        serviceName, advertiserNode.switch.peerInfo.privateKey
      )
      .encode()
      .get()
    let registrarPeerId = registrarNode.switch.peerInfo.peerId

    proc requestTicket(): Future[Ticket] {.async.} =
      let response: RegistrationResponse =
        (await advertiserNode.sendRegister(registrarPeerId, serviceId, adBytes)).get()
      check response.status == kad_protobuf.RegistrationStatus.Wait
      check response.ticket.isSome()
      return response.ticket.get()

    let first = await requestTicket()
    let second = await requestTicket()
    check:
      second.tWaitFor == first.tWaitFor
      second.tMod >= first.tMod

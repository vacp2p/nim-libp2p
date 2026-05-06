# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, std/[sequtils, tables]
import
  ../../../libp2p/[
    crypto/crypto,
    protocols/service_discovery,
    protocols/service_discovery/advertiser,
    protocols/service_discovery/discoverer,
    protocols/service_discovery/registrar,
    protocols/service_discovery/types,
    switch,
  ]
import ../../../libp2p/protocols/kademlia/protobuf as kad_protobuf
import ../../tools/[crypto, lifecycle, unittest]
import ./utils

suite "processRetryTicket":
  teardown:
    checkTrackers()

  test "no ticket returns t_wait":
    let disco = setupServiceDiscoveryNode()
    let ad = makeAdvertisement()
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: @[1'u8],
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )
    let tWait = 900.secs
    let tResult = disco.processRetryTicket(regMsg, ad, tWait)
    check tResult == tWait

  test "mismatched advertisement bytes returns t_wait":
    let disco = setupServiceDiscoveryNode()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    var ticket = Ticket(
      advertisement: @[0xAA'u8],
      tInit: Moment.init(1_000, Second),
      tMod: Moment.init(1_000, Second),
      tWaitFor: 0.secs,
      signature: @[],
    )
    check ticket.sign(key).isOk()
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: @[0xBB'u8],
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 900.secs
    let tResult = disco.processRetryTicket(regMsg, ad, tWait)
    check tResult == tWait

  test "invalid ticket signature returns t_wait":
    let disco = setupServiceDiscoveryNode()
    let ad = makeAdvertisement()
    let wrongKey = PrivateKey.random(rng[]).get()
    let adBytes = @[1'u8, 2, 3]
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: Moment.init(1_000, Second),
      tMod: Moment.init(1_000, Second),
      tWaitFor: 0.secs,
      signature: @[],
    )
    check ticket.sign(wrongKey).isOk()
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 900.secs
    let tResult = disco.processRetryTicket(regMsg, ad, tWait)
    check tResult == tWait

  test "expired ticket (window very far in past) returns t_wait":
    let disco = setupServiceDiscoveryNode()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    # window = [tMod+tWaitFor .. tMod+tWaitFor+delta]; tMod far in the past → outside
    let now = Moment.now()
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: Moment.init(1_000, Second),
      tMod: now - 100_000.secs,
      tWaitFor: 0.secs,
      signature: @[],
    )
    check ticket.sign(key).isOk()
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 900.secs
    let tResult = disco.processRetryTicket(regMsg, ad, tWait)
    check tResult == tWait

  test "retry before window start returns t_wait":
    let disco = setupServiceDiscoveryNode()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    # windowStart = now + 100 (in the future)
    let now = Moment.now()
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: now - 1000.secs,
      tMod: now,
      tWaitFor: 100.secs,
      signature: @[],
    )
    check ticket.sign(key).isOk()
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 900.secs
    let tResult = disco.processRetryTicket(regMsg, ad, tWait)
    check tResult == tWait

  test "retry after window end returns t_wait":
    let disco = setupServiceDiscoveryNode()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    # windowStart = now - 100, windowEnd = now - 99; now > windowEnd → outside
    let now = Moment.now()
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: now - 1000.secs,
      tMod: now - 100.secs,
      tWaitFor: 0.secs,
      signature: @[],
    )
    check ticket.sign(key).isOk()
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 900.secs
    let tResult = disco.processRetryTicket(regMsg, ad, tWait)
    check tResult == tWait

  test "valid retry within window returns t_remaining":
    let disco = setupServiceDiscoveryNode()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    # Set tMod = now, tWaitFor = 0 → windowStart = now (within window)
    # totalWaitSoFar = now - (now - 200) = 200 ± 1
    # t_remaining = 900 - 200 = 700 ± 1
    let now = Moment.now()
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: now - 200.secs,
      tMod: now,
      tWaitFor: 0.secs,
      signature: @[],
    )
    check ticket.sign(key).isOk()
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 900.secs
    let tResult = disco.processRetryTicket(regMsg, ad, tWait)
    check abs(tResult.secs - 700) <= 1

  test "valid retry with sufficient elapsed returns <= 0":
    let disco = setupServiceDiscoveryNode()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    # Set tMod = now, tWaitFor = 0 → windowStart = now (within window)
    # totalWaitSoFar = now - (now - 1000) = 1000 ± 1; tWait = 100 → negative
    let now = Moment.now()
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: now - 1000.secs,
      tMod: now,
      tWaitFor: 0.secs,
      signature: @[],
    )
    check ticket.sign(key).isOk()
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 100.secs
    let tResult = disco.processRetryTicket(regMsg, ad, tWait)
    check tResult <= ZeroDuration

suite "Component - handleRegister":
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

  asyncTest "REGISTER with malformed advertisement bytes returns Rejected":
    let registrarNode = setupServiceDiscoveryNode()
    let advertiserNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceId = makeServiceId()
    let adBytes = @[1'u8, 2, 3, 4]
      # malformed — validateRegisterMessage rejects before ticket check

    let regResp = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check regResp.isOk()
    check regResp.get().status == kad_protobuf.RegistrationStatus.Rejected

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
    # window = [tMod+tWaitFor .. tMod+tWaitFor+registrationWindow(1s)] = [now-10000000 .. now-999999]
    # now is well past the window, so processRetryTicket ignores the ticket
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

suite "Component - handleGetAds":
  teardown:
    checkTrackers()

  asyncTest "GET_ADS on empty registrar cache returns no ads":
    let registrarNode = setupServiceDiscoveryNode()
    let discovererNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, discovererNode])
    await connect(registrarNode, discovererNode)

    let serviceId = "empty-service".hashServiceId()
    let lookupResp = await discovererNode.lookup(serviceId)
    check lookupResp.isOk()
    check lookupResp.get().len == 0

  asyncTest "GET_ADS returns ads stored in registrar cache":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, advertiserNode, discovererNode])
    await connect(registrarNode, advertiserNode)
    await connect(registrarNode, discovererNode)

    let serviceName = "cached-service"
    let serviceId = serviceName.hashServiceId()
    let adBytes = makeAdvertisement(
        serviceName, advertiserNode.switch.peerInfo.privateKey
      )
      .encode()
      .get()

    # Register with registrar (safetyParam=0 → Confirmed → stored in cache)
    let regResult = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check regResult.isOk()
    check regResult.get().status == kad_protobuf.RegistrationStatus.Confirmed

    # Discoverer queries registrar via lookup
    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len == 1
    check found.get()[0].data.peerId == advertiserNode.switch.peerInfo.peerId

  asyncTest "GET_ADS respects F_return limit":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0, fReturn = 2)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, discovererNode])
    await connect(registrarNode, discovererNode)

    let serviceName = "limited-service"
    let serviceId = serviceName.hashServiceId()

    # Directly populate the registrar cache with 4 distinct ads
    for _ in 0 ..< 4:
      let ad = makeAdvertisement(serviceName)
      registrarNode.acceptAdvertisement(serviceId, ad)

    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len <= 2

suite "Component - end-to-end":
  teardown:
    checkTrackers()

  asyncTest "addProvidedService registers service, lookup finds it":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    # Using 2 registrars reduces the chance of dropping a peer whose
    # bucket index falls outside the default bucket range
    # (`Default_M_buckets = 16`). This reduces the failure rate to 1 in 4_294_967_296.
    let registrarNode1 = setupServiceDiscoveryNode(discoConfig = conf)
    let registrarNode2 = setupServiceDiscoveryNode(discoConfig = conf)
    let advertiserNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode1, registrarNode2, advertiserNode, discovererNode])

    # Advertiser and discoverer both know about the registrar
    await connect(registrarNode1, advertiserNode)
    await connect(registrarNode2, advertiserNode)
    await connect(registrarNode1, discovererNode)
    await connect(registrarNode2, discovererNode)

    let service = makeServiceInfo("e2e-test-service")
    let serviceId = service.id.hashServiceId()

    # Sync call — spawns background REGISTER task to registrar
    advertiserNode.addProvidedService(service)

    # Wait until registrar stores the advertisement
    checkUntilTimeout:
      (
        registrarNode1.registrar.cache.getOrDefault(serviceId, @[]).len == 1 or
        registrarNode2.registrar.cache.getOrDefault(serviceId, @[]).len == 1
      )

    # Discoverer looks up and finds it
    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len >= 1
    check found.get().anyIt(it.data.peerId == advertiserNode.switch.peerInfo.peerId)

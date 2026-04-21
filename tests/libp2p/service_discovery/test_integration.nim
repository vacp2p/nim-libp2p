# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[times]
import chronos, results
import ../../../libp2p/[switch, crypto/crypto]
import ../../../libp2p/protocols/service_discovery
import
  ../../../libp2p/protocols/service_discovery/[types, registrar, advertiser, discoverer]
import ../../../libp2p/protocols/[kademlia]
import ../../../libp2p/protocols/kademlia/protobuf as kad_protobuf
import ../../tools/[unittest, lifecycle, crypto]
import ./utils

proc setupDiscoNode(
    discoConf: ServiceDiscoveryConfig = ServiceDiscoveryConfig.new()
): ServiceDiscovery =
  let switch = createSwitch()
  let kad = ServiceDiscovery.new(
    switch,
    bootstrapNodes = @[],
    config = KadDHTConfig.new(
      ExtEntryValidator(),
      ExtEntrySelector(),
      timeout = chronos.seconds(1),
      cleanupProvidersInterval = chronos.milliseconds(100),
      providerExpirationInterval = chronos.seconds(1),
      republishProvidedKeysInterval = chronos.milliseconds(50),
    ),
    discoConfig = discoConf,
    xprPublishing = false,
  )
  switch.mount(kad)
  kad

suite "processRetryTicket":
  teardown:
    checkTrackers()

  test "no ticket returns t_wait":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement()
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: @[1'u8],
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )
    let tResult = disco.processRetryTicket(regMsg, ad, 900.0, 1000)
    check abs(tResult - 900.0) < 0.001

  test "mismatched advertisement bytes returns t_wait":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    var ticket = Ticket(
      advertisement: @[0xAA'u8], tInit: 1000, tMod: 1000, tWaitFor: 0, signature: @[]
    )
    discard ticket.sign(key)
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: @[0xBB'u8],
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tResult = disco.processRetryTicket(regMsg, ad, 900.0, 1001)
    check abs(tResult - 900.0) < 0.001

  test "invalid ticket signature returns t_wait":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement()
    let wrongKey = PrivateKey.random(rng[]).get()
    let adBytes = @[1'u8, 2, 3]
    var ticket = Ticket(
      advertisement: adBytes, tInit: 1000, tMod: 1000, tWaitFor: 0, signature: @[]
    )
    discard ticket.sign(wrongKey)
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tResult = disco.processRetryTicket(regMsg, ad, 900.0, 1001)
    check abs(tResult - 900.0) < 0.001

  test "expired ticket (window very far in past) returns t_wait":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    # window = [tMod+tWaitFor .. tMod+tWaitFor+delta] = [1000..1001]
    # now = 1_000_000 is far past the window
    var ticket = Ticket(
      advertisement: adBytes, tInit: 1000, tMod: 1000, tWaitFor: 0, signature: @[]
    )
    discard ticket.sign(key)
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tResult = disco.processRetryTicket(regMsg, ad, 900.0, 1_000_000)
    check abs(tResult - 900.0) < 0.001

  test "retry before window start returns t_wait":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    # windowStart = tMod + tWaitFor = 1000 + 100 = 1100; now = 1050 < 1100
    var ticket = Ticket(
      advertisement: adBytes, tInit: 1000, tMod: 1000, tWaitFor: 100, signature: @[]
    )
    discard ticket.sign(key)
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tResult = disco.processRetryTicket(regMsg, ad, 900.0, 1050)
    check abs(tResult - 900.0) < 0.001

  test "retry after window end returns t_wait":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    # window = [1000..1001] (delta=1s); now = 1005 > windowEnd
    var ticket = Ticket(
      advertisement: adBytes, tInit: 1000, tMod: 1000, tWaitFor: 0, signature: @[]
    )
    discard ticket.sign(key)
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tResult = disco.processRetryTicket(regMsg, ad, 900.0, 1005)
    check abs(tResult - 900.0) < 0.001

  test "valid retry within window returns t_remaining":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    # windowStart = tMod + tWaitFor = 1100 + 100 = 1200; window = [1200..1201]
    # now = 1200 → inside window
    # totalWaitSoFar = now - tInit = 1200 - 1000 = 200
    # t_remaining = 900 - 200 = 700
    var ticket = Ticket(
      advertisement: adBytes, tInit: 1000, tMod: 1100, tWaitFor: 100, signature: @[]
    )
    discard ticket.sign(key)
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tResult = disco.processRetryTicket(regMsg, ad, 900.0, 1200)
    check abs(tResult - 700.0) < 0.001

  test "valid retry with sufficient elapsed returns <= 0":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    # windowStart = tMod + tWaitFor = 1900 + 100 = 2000; window = [2000..2001]
    # now = 2000 → inside window
    # totalWaitSoFar = now - tInit = 2000 - 1000 = 1000
    # t_remaining = 100 - 1000 = -900 <= 0
    var ticket = Ticket(
      advertisement: adBytes, tInit: 1000, tMod: 1900, tWaitFor: 100, signature: @[]
    )
    discard ticket.sign(key)
    let regMsg = kad_protobuf.RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tResult = disco.processRetryTicket(regMsg, ad, 100.0, 2000)
    check tResult <= 0.0

suite "Integration - handleRegister":
  teardown:
    checkTrackers()

  asyncTest "first REGISTER with no ticket returns Wait":
    let registrarNode = setupDiscoNode()
    let advertiserNode = setupDiscoNode()
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

  asyncTest "REGISTER with wrong-key ticket returns Rejected":
    let registrarNode = setupDiscoNode()
    let advertiserNode = setupDiscoNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceId = makeServiceId()
    let adBytes = @[1'u8, 2, 3, 4] # malformed — validateRegisterMessage rejects
    let wrongKey = PrivateKey.random(rng[]).get()
    var ticket = Ticket(
      advertisement: adBytes, tInit: 1000, tMod: 1000, tWaitFor: 0, signature: @[]
    )
    discard ticket.sign(wrongKey)

    let regResp = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes, Opt.some(ticket)
    )
    check regResp.isOk()
    check regResp.get().status == kad_protobuf.RegistrationStatus.Rejected

  asyncTest "REGISTER with out-of-window ticket returns Rejected":
    let registrarNode = setupDiscoNode()
    let advertiserNode = setupDiscoNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceId = makeServiceId()
    let adBytes = @[1'u8, 2, 3, 4] # malformed — validateRegisterMessage rejects
    let registrarKey = registrarNode.switch.peerInfo.privateKey
    let now = getTime().toUnix().uint64
    # Window was [now-1000 .. now-999]; we are well past it
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: now - 1000,
      tMod: now - 1000,
      tWaitFor: 0,
      signature: @[],
    )
    discard ticket.sign(registrarKey)

    let regResp = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes, Opt.some(ticket)
    )
    check regResp.isOk()
    check regResp.get().status == kad_protobuf.RegistrationStatus.Rejected

  asyncTest "REGISTER with safetyParam=0 returns Confirmed on first attempt":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupDiscoNode(conf)
    let advertiserNode = setupDiscoNode(conf)
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

suite "Integration - handleGetAds":
  teardown:
    checkTrackers()

  asyncTest "GET_ADS on empty registrar cache returns no ads":
    let registrarNode = setupDiscoNode()
    let discovererNode = setupDiscoNode()
    startAndDeferStop(@[registrarNode, discovererNode])
    await connect(registrarNode, discovererNode)

    let serviceId = "empty-service".hashServiceId()
    let lookupResp = await discovererNode.lookup(serviceId)
    check lookupResp.isOk()
    check lookupResp.get().len == 0

  asyncTest "GET_ADS returns ads stored in registrar cache":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupDiscoNode(conf)
    let advertiserNode = setupDiscoNode(conf)
    let discovererNode = setupDiscoNode(conf)
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
    let registrarNode = setupDiscoNode(conf)
    let discovererNode = setupDiscoNode(conf)
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

suite "Integration - end-to-end":
  teardown:
    checkTrackers()

  asyncTest "addProvidedService registers service, lookup finds it":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupDiscoNode(conf)
    let advertiserNode = setupDiscoNode(conf)
    let discovererNode = setupDiscoNode(conf)
    startAndDeferStop(@[registrarNode, advertiserNode, discovererNode])

    # Advertiser and discoverer both know about the registrar
    await connect(registrarNode, advertiserNode)
    await connect(registrarNode, discovererNode)

    let service = makeServiceInfo("e2e-test-service")
    let serviceId = service.id.hashServiceId()

    # Sync call — spawns background REGISTER task to registrar
    advertiserNode.addProvidedService(service)

    # Wait until registrar stores the advertisement
    checkUntilTimeout:
      registrarNode.registrar.cache.getOrDefault(serviceId, @[]).len == 1

    # Discoverer looks up and finds it
    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len >= 1
    check found.get()[0].data.peerId == advertiserNode.switch.peerInfo.peerId

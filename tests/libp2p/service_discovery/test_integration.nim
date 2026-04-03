# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[times]
import chronos, results
import ../../../libp2p/[peerid, crypto/crypto, multiaddress, extended_peer_record]
import ../../../libp2p/protocols/kad_disco
import ../../../libp2p/protocols/kademlia_discovery/types as kd_types
import ../../../libp2p/protocols/kademlia/protobuf as kad_protobuf
import ../../../libp2p/protocols/service_discovery/[types, registrar, advertiser]
import ../../tools/[unittest, lifecycle]
import ./utils

proc setupDiscoNode(
    discoConf: KademliaDiscoveryConfig = KademliaDiscoveryConfig.new()
): KademliaDiscovery =
  let switch = createSwitch()
  let kad = KademliaDiscovery.new(
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
    discoConf = discoConf,
    xprPublishing = false,
  )
  switch.mount(kad)
  kad

# ===========================================================================
# processRetryTicket unit tests (no network)
# ===========================================================================

suite "processRetryTicket":
  teardown:
    checkTrackers()

  test "no ticket returns Opt.some(t_wait)":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement()
    let regMsg = RegisterMessage(
      advertisement: @[1'u8],
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )
    let result = disco.processRetryTicket(regMsg, ad, 900.0, 1000)
    check result.isSome()
    check abs(result.get() - 900.0) < 0.001

  test "mismatched advertisement bytes returns Opt.none":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    var ticket = Ticket(
      advertisement: @[0xAA'u8],
      tInit: 1000,
      tMod: 1000,
      tWaitFor: 0,
      expiresAt: 1002,
      nonce: @[],
    )
    discard ticket.sign(key)
    let regMsg = RegisterMessage(
      advertisement: @[0xBB'u8],
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    check disco.processRetryTicket(regMsg, ad, 900.0, 1001).isNone()

  test "invalid ticket signature returns Opt.none":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement()
    let wrongKey = PrivateKey.random(rng[]).get()
    let adBytes = @[1'u8, 2, 3]
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: 1000,
      tMod: 1000,
      tWaitFor: 0,
      expiresAt: 1002,
      nonce: @[],
    )
    discard ticket.sign(wrongKey)
    let regMsg = RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    check disco.processRetryTicket(regMsg, ad, 900.0, 1001).isNone()

  test "expired ticket returns Opt.none":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: 1000,
      tMod: 1000,
      tWaitFor: 0,
      expiresAt: 1001,
      nonce: @[],
    )
    discard ticket.sign(key)
    let regMsg = RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    # now=1002 > expiresAt=1001
    check disco.processRetryTicket(regMsg, ad, 900.0, 1002).isNone()

  test "retry before window start returns Opt.none":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: 1000,
      tMod: 1000,
      tWaitFor: 100, # window starts at tMod+tWaitFor = 1100
      expiresAt: 1200,
      nonce: @[],
    )
    discard ticket.sign(key)
    let regMsg = RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    # now=1050, windowStart=1100 → too early
    check disco.processRetryTicket(regMsg, ad, 900.0, 1050).isNone()

  test "retry after window end returns Opt.none":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: 1000,
      tMod: 1000,
      tWaitFor: 0, # window is [1000..1001] (delta=1s)
      expiresAt: 9999,
      nonce: @[],
    )
    discard ticket.sign(key)
    let regMsg = RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    # now=1005, windowEnd=1001 → too late
    check disco.processRetryTicket(regMsg, ad, 900.0, 1005).isNone()

  test "valid retry within window returns Opt.some with t_remaining":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: 1000,
      tMod: 1100,
      tWaitFor: 100, # window starts at 1200
      expiresAt: 9999,
      nonce: @[],
    )
    discard ticket.sign(key)
    let regMsg = RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    # now=1200, within window [1200..1201]
    # totalWaitSoFar = 1200 - 1000 = 200
    # t_remaining = 900 - 200 = 700
    let result = disco.processRetryTicket(regMsg, ad, 900.0, 1200)
    check result.isSome()
    check abs(result.get() - 700.0) < 0.001

  test "valid retry with sufficient elapsed returns Opt.some(<=0)":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement()
    let key = disco.switch.peerInfo.privateKey
    let adBytes = @[1'u8, 2, 3]
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: 1000,
      tMod: 1900,
      tWaitFor: 100, # window starts at 2000
      expiresAt: 9999,
      nonce: @[],
    )
    discard ticket.sign(key)
    let regMsg = RegisterMessage(
      advertisement: adBytes,
      status: Opt.none(kad_protobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    # now=2000, tInit=1000, totalWaitSoFar=1000
    # t_wait=100, t_remaining = 100 - 1000 = -900 <= 0
    let result = disco.processRetryTicket(regMsg, ad, 100.0, 2000)
    check result.isSome()
    check result.get() <= 0.0

# ===========================================================================
# handleRegister integration tests
# ===========================================================================

suite "Integration - handleRegister":
  teardown:
    checkTrackers()

  asyncTest "first REGISTER with no ticket returns Wait":
    let registrarNode = setupDiscoNode()
    let advertiserNode = setupDiscoNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let service = makeServiceInfo()
    advertiserNode.services.incl(service)
    let serviceId = service.id.hashServiceId()
    let adBytes = advertiserNode.record().get().encode().get()

    let result = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check result.isOk()
    let (status, ticketOpt, _) = result.get()
    check status == kad_protobuf.RegistrationStatus.Wait
    check ticketOpt.isSome()

  asyncTest "REGISTER with wrong-key ticket returns Rejected":
    let registrarNode = setupDiscoNode()
    let advertiserNode = setupDiscoNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceId = makeServiceId()
    let adBytes = @[1'u8, 2, 3, 4]
    let wrongKey = PrivateKey.random(rng[]).get()
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: 1000,
      tMod: 1000,
      tWaitFor: 0,
      expiresAt: uint64.high,
      nonce: @[],
    )
    discard ticket.sign(wrongKey)

    let result = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes, Opt.some(ticket)
    )
    check result.isOk()
    check result.get()[0] == kad_protobuf.RegistrationStatus.Rejected

  asyncTest "REGISTER with out-of-window ticket returns Rejected":
    let registrarNode = setupDiscoNode()
    let advertiserNode = setupDiscoNode()
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let serviceId = makeServiceId()
    let adBytes = @[1'u8, 2, 3, 4]
    let registrarKey = registrarNode.switch.peerInfo.privateKey
    let now = getTime().toUnix().uint64
    # Window was [now-1000 .. now-999]; we are well past it
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: now - 1000,
      tMod: now - 1000,
      tWaitFor: 0,
      expiresAt: now + 9999,
      nonce: @[],
    )
    discard ticket.sign(registrarKey)

    let result = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes, Opt.some(ticket)
    )
    check result.isOk()
    check result.get()[0] == kad_protobuf.RegistrationStatus.Rejected

  asyncTest "REGISTER with safetyParam=0 returns Confirmed on first attempt":
    let conf = KademliaDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupDiscoNode(conf)
    let advertiserNode = setupDiscoNode(conf)
    startAndDeferStop(@[registrarNode, advertiserNode])
    await connect(registrarNode, advertiserNode)

    let service = makeServiceInfo()
    advertiserNode.services.incl(service)
    let serviceId = service.id.hashServiceId()
    let adBytes = advertiserNode.record().get().encode().get()

    let result = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check result.isOk()
    check result.get()[0] == kad_protobuf.RegistrationStatus.Confirmed

# ===========================================================================
# handleGetAds integration tests
# ===========================================================================

suite "Integration - handleGetAds":
  teardown:
    checkTrackers()

  asyncTest "GET_ADS on empty registrar cache returns no ads":
    let registrarNode = setupDiscoNode()
    let discovererNode = setupDiscoNode()
    startAndDeferStop(@[registrarNode, discovererNode])
    await connect(registrarNode, discovererNode)

    let service = makeServiceInfo()
    # Lookup creates the search table from the main routing table,
    # which contains the registrar (added by connect above).
    let result = await discovererNode.lookup(service.id.hashServiceId())
    check result.isOk()
    check result.get().len == 0

  asyncTest "GET_ADS returns ads stored in registrar cache":
    let conf = KademliaDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupDiscoNode(conf)
    let advertiserNode = setupDiscoNode(conf)
    let discovererNode = setupDiscoNode(conf)
    startAndDeferStop(@[registrarNode, advertiserNode, discovererNode])
    await connect(registrarNode, advertiserNode)
    await connect(registrarNode, discovererNode)

    let service = makeServiceInfo()
    advertiserNode.services.incl(service)
    let serviceId = service.id.hashServiceId()
    let adBytes = advertiserNode.record().get().encode().get()

    # Register directly with registrar (safetyParam=0 → Confirmed)
    let regResult = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check regResult.isOk()
    check regResult.get()[0] == kad_protobuf.RegistrationStatus.Confirmed

    # Discoverer queries registrar via lookup
    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len == 1
    check found.get()[0].data.peerId == advertiserNode.switch.peerInfo.peerId

  asyncTest "GET_ADS respects F_return limit":
    let conf = KademliaDiscoveryConfig.new(safetyParam = 0.0, fReturn = 2)
    let registrarNode = setupDiscoNode(conf)
    let discovererNode = setupDiscoNode(conf)
    startAndDeferStop(@[registrarNode, discovererNode])
    await connect(registrarNode, discovererNode)

    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    # Register 4 advertisers with the registrar
    for _ in 0 ..< 4:
      let advNode = setupDiscoNode(conf)
      await advNode.switch.start()
      defer:
        await advNode.switch.stop()
      advNode.services.incl(service)
      let adBytes = advNode.record().get().encode().get()
      let r = await advNode.sendRegister(
        registrarNode.switch.peerInfo.peerId, serviceId, adBytes
      )
      check r.isOk()
      check r.get()[0] == kad_protobuf.RegistrationStatus.Confirmed

    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len <= 2 # F_return = 2

# ===========================================================================
# End-to-end test
# ===========================================================================

suite "Integration - end-to-end":
  teardown:
    checkTrackers()

  asyncTest "addProvidedService registers service, lookup finds it":
    let conf = KademliaDiscoveryConfig.new(safetyParam = 0.0)
    let registrarNode = setupDiscoNode(conf)
    let advertiserNode = setupDiscoNode(conf)
    let discovererNode = setupDiscoNode(conf)
    startAndDeferStop(@[registrarNode, advertiserNode, discovererNode])

    # advertiser knows about registrar
    await connect(registrarNode, advertiserNode)
    # discoverer knows about registrar
    await connect(registrarNode, discovererNode)

    let service = makeServiceInfo("e2e-test-service")

    # Advertiser publishes service (spawns async registration with registrar)
    await advertiserNode.addProvidedService(service)

    # Wait until registrar has the ad
    let serviceId = service.id.hashServiceId()
    checkUntilTimeout:
      registrarNode.registrar.cache.getOrDefault(serviceId, @[]).len == 1

    # Discoverer finds it
    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len >= 1
    check found.get()[0].data.peerId == advertiserNode.switch.peerInfo.peerId

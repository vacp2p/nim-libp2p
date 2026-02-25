# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[times, net, math]
import chronos, chronicles, results
import
  ../../../libp2p/[
    peerid,
    multiaddress,
    extended_peer_record,
    routing_record,
    crypto/crypto,
    signed_envelope,
  ]
import ../../../libp2p/protocols/capability_discovery/[types, registrar, iptree]
import ../../tools/unittest
import ./utils

# ===========================================================================
# UNIT TESTS
# ===========================================================================

# ---------------------------------------------------------------------------
# Waiting Time Formula
# ---------------------------------------------------------------------------

suite "Registrar - waitingTime formula":
  test "empty cache, no IP similarity: w = E * G":
    # RFC formula: w = E * occupancy * (serviceSim + ipSim + G)
    # Empty cache → occupancy = 1.0, serviceSim = 0, ipSim = 0
    # → w = E * 1.0 * G
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let serviceId = makeServiceId()
    let now = makeNow()

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)
    let expected = discoConf.advertExpiry * discoConf.safetyParam

    check abs(w - expected) < 0.001

  test "exact formula at 50% occupancy with P_occ=1":
    # occupancy = 1 / (1 - 0.5)^1 = 2.0
    # w = E * 2.0 * G (no service or IP sim)
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new(occupancyExp = 1.0)
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let serviceId = makeServiceId()
    let now = makeNow()

    fillCache(registrar, 500, now)

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)
    let expected = discoConf.advertExpiry * 2.0 * discoConf.safetyParam

    check abs(w - expected) < 0.01

  test "occupancy increases monotonically as cache fills":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement()
    let serviceId = makeServiceId()
    let now = makeNow()

    let w0 = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)
    fillCache(registrar, 500, now)
    let w50 = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)
    fillCache(registrar, 499, now) # total ~999
    let w99 = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w50 > w0
    check w99 > w50

  test "at capacity: w uses 100x multiplier floor":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement()
    let serviceId = makeServiceId()
    let now = makeNow()

    fillCache(registrar, 1000, now) # fill to cap

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)
    let floor = discoConf.advertExpiry * 100.0 * discoConf.safetyParam

    check w >= floor

  test "service similarity contributes proportionally":
    # Two ads for same service → serviceSim = 2/1000
    # vs zero ads → serviceSim = 0
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let now = makeNow()

    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let w_before = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    let ad2 = createTestAdvertisement(serviceId = serviceId)
    let ad3 = createTestAdvertisement(serviceId = serviceId)
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad3.toAdvertisementKey()] = now
    registrar.cache[serviceId] = @[ad2, ad3]

    let w_after = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w_after > w_before

  test "IP similarity increases wait time for same-subnet advertiser":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let now = makeNow()

    let adClean = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let w_clean = registrar.waitingTime(discoConf, adClean, 1000, serviceId, now)

    registrar.ipTree.insertIp(parseIpAddress("192.168.1.10"))
    registrar.ipTree.insertIp(parseIpAddress("192.168.1.20"))
    registrar.ipTree.insertIp(parseIpAddress("192.168.1.30"))

    let adSimilar =
      createTestAdvertisement(addrs = @[createTestMultiAddress("192.168.1.50")])
    let w_similar = registrar.waitingTime(discoConf, adSimilar, 1000, serviceId, now)

    check w_similar > w_clean

  test "uses maximum IP score across multiple addresses":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let now = makeNow()

    registrar.ipTree.insertIp(parseIpAddress("192.168.1.10"))
    registrar.ipTree.insertIp(parseIpAddress("192.168.1.20"))

    # One low-similarity addr + one high-similarity addr → should pick high
    let adHigh =
      createTestAdvertisement(addrs = @[createTestMultiAddress("192.168.1.50")])
    let adLow = createTestAdvertisement(addrs = @[createTestMultiAddress("1.2.3.4")])

    let wHigh = registrar.waitingTime(discoConf, adHigh, 1000, serviceId, now)
    let wLow = registrar.waitingTime(discoConf, adLow, 1000, serviceId, now)

    check wHigh > wLow

  test "E and G both scale result proportionally (parameter sanity)":
    # Both advertExpiry (E) and safetyParam (G) multiply the result linearly.
    # Larger E → larger w; larger G → larger w.
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let serviceId = makeServiceId()
    let now = makeNow()

    let wLowE = registrar.waitingTime(
      KademliaDiscoveryConfig.new(advertExpiry = 100.0), ad, 1000, serviceId, now
    )
    let wHighE = registrar.waitingTime(
      KademliaDiscoveryConfig.new(advertExpiry = 2000.0), ad, 1000, serviceId, now
    )
    let wLowG = registrar.waitingTime(
      KademliaDiscoveryConfig.new(safetyParam = 0.0001), ad, 1000, serviceId, now
    )
    let wHighG = registrar.waitingTime(
      KademliaDiscoveryConfig.new(safetyParam = 1.0), ad, 1000, serviceId, now
    )

    check wHighE > wLowE
    check wHighG > wLowG

  test "no addresses: ipSim = 0, does not crash":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement(addrs = @[])
    let serviceId = makeServiceId()
    let now = makeNow()

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    let expected = discoConf.advertExpiry * discoConf.safetyParam
    check abs(w - expected) < 0.001

  test "IPv6-only addresses: treated same as no addresses":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    let ad = createTestAdvertisement(addrs = @[ipv6Addr])
    let serviceId = makeServiceId()
    let now = makeNow()

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)
    let expected = discoConf.advertExpiry * discoConf.safetyParam

    check abs(w - expected) < 0.001

  test "smaller cache cap = higher occupancy at same fill count":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement()
    let serviceId = makeServiceId()
    let now = makeNow()

    fillCache(registrar, 100, now)

    let wSmallCap = registrar.waitingTime(discoConf, ad, 100, serviceId, now)
    let wLargeCap = registrar.waitingTime(discoConf, ad, 10000, serviceId, now)

    check wSmallCap > wLargeCap

  test "higher occupancyExp = steeper wait curve at same occupancy":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let serviceId = makeServiceId()
    let now = makeNow()

    fillCache(registrar, 500, now)

    let w1 = registrar.waitingTime(
      KademliaDiscoveryConfig.new(occupancyExp = 1.0), ad, 1000, serviceId, now
    )
    let w2 = registrar.waitingTime(
      KademliaDiscoveryConfig.new(occupancyExp = 20.0), ad, 1000, serviceId, now
    )

    check w2 > w1

# ---------------------------------------------------------------------------
# Lower Bound Enforcement
# ---------------------------------------------------------------------------

suite "Registrar - lower bound enforcement in waitingTime":
  test "service lower bound overrides formula when higher":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    # Formula gives ~E*G ≈ 0.000090 — tiny
    # Bound set to 1500 at t=1000 → effective = 1500 - 0 = 1500
    registrar.boundService[serviceId] = 1500.0
    registrar.timestampService[serviceId] = 1000

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 1500.0

  test "service lower bound decreases as time passes":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)

    # bound = 1500 at t=1000 → effective at t=1500 = 1500 - 500 = 1000
    registrar.boundService[serviceId] = 1500.0
    registrar.timestampService[serviceId] = 1000

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, 2000)

    # effective bound = 1500 - (2000 - 1000) = 500
    check w >= 500.0
    check w < 1500.0

  test "expired service lower bound (elapsed > bound) does not inflate w":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)

    # bound was 100 set at t=0 → at t=5000 effective = 100 - 5000 = -4900 (negative)
    registrar.boundService[serviceId] = 100.0
    registrar.timestampService[serviceId] = 0

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, 5000)
    let formula = discoConf.advertExpiry * discoConf.safetyParam

    # Negative bound should not override formula
    check abs(w - formula) < 0.001

  test "IP lower bound overrides formula when higher":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ip = "192.168.1.50"
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress(ip)])
    let serviceId = makeServiceId()
    let now: uint64 = 1000

    registrar.boundIp[ip] = 1500.0
    registrar.timestampIp[ip] = 1000

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 1500.0

  test "most restrictive bound (service vs IP) wins":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ip = "192.168.1.1"
    let now: uint64 = 1000

    registrar.boundService[serviceId] = 2000.0
    registrar.timestampService[serviceId] = 1000

    registrar.boundIp[ip] = 5000.0 # More restrictive
    registrar.timestampIp[ip] = 1000

    let ad = createTestAdvertisement(
      serviceId = serviceId, addrs = @[createTestMultiAddress(ip)]
    )
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 5000.0 # effective IP bound = 5000 - (now - timestampIp) = 5000 - 0 = 5000

  test "IP bound is per-address: unrelated IP not affected":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let now: uint64 = 1000

    registrar.boundIp["192.168.1.1"] = 2000.0
    registrar.timestampIp["192.168.1.1"] = 1000

    let adUnrelated =
      createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adAffected =
      createTestAdvertisement(addrs = @[createTestMultiAddress("192.168.1.1")])

    let wUnrelated = registrar.waitingTime(discoConf, adUnrelated, 1000, serviceId, now)
    let wAffected = registrar.waitingTime(discoConf, adAffected, 1000, serviceId, now)

    check wAffected > wUnrelated

# ---------------------------------------------------------------------------
# Lower Bound Updates
# ---------------------------------------------------------------------------

suite "Registrar - updateLowerBounds":
  test "stores bound as w + now for new service":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000
    let w = 500.0

    updateLowerBounds(registrar, serviceId, ad, w, now)

    check registrar.boundService[serviceId] == w + float64(now) # 1500
    check registrar.timestampService[serviceId] == now

  test "updates bound when new w exceeds effective bound":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    # Existing: bound=1500, timestamp=500 → effective = 1500 - 500 = 1000
    registrar.boundService[serviceId] = 1500.0
    registrar.timestampService[serviceId] = 500

    # New w=1200 > effective=1000 → update
    updateLowerBounds(registrar, serviceId, ad, 1200.0, now)

    check registrar.boundService[serviceId] == 1200.0 + 1000.0
    check registrar.timestampService[serviceId] == now

  test "does not decrease bound when new w is lower":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    # Existing: bound=2500, timestamp=500 → effective = 2500 - 500 = 2000
    registrar.boundService[serviceId] = 2500.0
    registrar.timestampService[serviceId] = 500
    let oldBound = registrar.boundService[serviceId]

    # New w=1000 < effective=2000 → no update
    updateLowerBounds(registrar, serviceId, ad, 1000.0, now)

    check registrar.boundService[serviceId] == oldBound

  test "updates IP bound for each IPv4 address":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let ad = createTestAdvertisement(
      serviceId = serviceId,
      addrs = @[createTestMultiAddress(ip1), createTestMultiAddress(ip2)],
    )
    let now: uint64 = 1000

    updateLowerBounds(registrar, serviceId, ad, 500.0, now)

    check registrar.boundIp[ip1] == 500.0 + 1000.0
    check registrar.boundIp[ip2] == 500.0 + 1000.0
    check registrar.timestampIp[ip1] == now
    check registrar.timestampIp[ip2] == now

  test "accumulated bound across multiple calls":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)

    # Call 1: t=1000, w=500 → bound=1500
    updateLowerBounds(registrar, serviceId, ad, 500.0, 1000)
    check registrar.boundService[serviceId] == 1500.0

    # Call 2: t=1500, w=800
    # effective = 1500 - (1500-1000) = 1000; w=800 < 1000 → no update
    updateLowerBounds(registrar, serviceId, ad, 800.0, 1500)
    check registrar.boundService[serviceId] == 1500.0

    # Call 3: t=2000, w=1200
    # effective = 1500 - (2000-1000) = 500; w=1200 > 500 → update
    updateLowerBounds(registrar, serviceId, ad, 1200.0, 2000)
    check registrar.boundService[serviceId] == 3200.0 # 1200 + 2000

  test "empty addresses: service bound updated, no IP bound entries":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId, addrs = @[])

    updateLowerBounds(registrar, serviceId, ad, 500.0, 1000)

    check serviceId in registrar.boundService
    check registrar.boundIp.len == 0

# ---------------------------------------------------------------------------
# Cache Pruning
# ---------------------------------------------------------------------------

suite "Registrar - pruneExpiredAds":
  test "empty registrar: no-op":
    let registrar = createTestRegistrar()
    pruneExpiredAds(registrar, 900)
    check registrar.cache.len == 0
    check registrar.cacheTimestamps.len == 0

  test "fresh ad is kept":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now = makeNow()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now

    pruneExpiredAds(registrar, 900)

    check ad in registrar.cache[serviceId]
    check ad.toAdvertisementKey() in registrar.cacheTimestamps

  test "expired ad is removed from cache, timestamps, and IP tree":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ip = "192.168.1.1"
    let ad = createTestAdvertisement(
      serviceId = serviceId, addrs = @[createTestMultiAddress(ip)]
    )
    let now = makeNow()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000
    registrar.ipTree.insertIp(parseIpAddress(ip))

    pruneExpiredAds(registrar, 900)

    check ad notin registrar.cache[serviceId]
    check ad.toAdvertisementKey() notin registrar.cacheTimestamps
    check registrar.ipTree.root.counter == 0

  test "IP not removed when another active ad shares the same IP":
    # RFC: remove IP only if no other active ads from same IP remain
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ip = "192.168.1.1"
    let now = makeNow()

    let adExpired = createTestAdvertisement(
      serviceId = serviceId, addrs = @[createTestMultiAddress(ip)]
    )
    let adFresh = createTestAdvertisement(
      serviceId = serviceId, addrs = @[createTestMultiAddress(ip)]
    )

    registrar.cache[serviceId] = @[adExpired, adFresh]
    registrar.cacheTimestamps[adExpired.toAdvertisementKey()] = now - 1000
    registrar.cacheTimestamps[adFresh.toAdvertisementKey()] = now
    registrar.ipTree.insertIp(parseIpAddress(ip)) # represents both ads
    registrar.ipTree.insertIp(parseIpAddress(ip))

    pruneExpiredAds(registrar, 900)

    # adFresh survives; tree should still have 1 entry
    check adFresh in registrar.cache[serviceId]
    check registrar.ipTree.root.counter == 1

  test "mixed expired and fresh: only expired removed":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let now = makeNow()

    let ad1 = createTestAdvertisement(serviceId = serviceId)
    let ad2 = createTestAdvertisement(serviceId = serviceId)
    let ad3 = createTestAdvertisement(serviceId = serviceId)

    registrar.cache[serviceId] = @[ad1, ad2, ad3]
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now - 1000 # expired
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now # fresh
    registrar.cacheTimestamps[ad3.toAdvertisementKey()] = now - 2000 # expired

    pruneExpiredAds(registrar, 900)

    check registrar.cache[serviceId].len == 1
    check ad2 in registrar.cache[serviceId]

  test "ad with no IPv4 addresses: does not crash on prune":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId, addrs = @[])
    let now = makeNow()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000

    pruneExpiredAds(registrar, 900)

    check ad notin registrar.cache[serviceId]

# ---------------------------------------------------------------------------
# validateRegisterMessage
# ---------------------------------------------------------------------------

suite "Registrar - validateRegisterMessage":
  test "empty advertisement bytes → none":
    let regMsg = RegisterMessage(advertisement: @[])
    check validateRegisterMessage(regMsg).isNone()

  test "corrupted bytes → none":
    let regMsg = RegisterMessage(advertisement: @[0xFF.byte, 0x00.byte, 0xAB.byte])
    check validateRegisterMessage(regMsg).isNone()

  test "valid encoded advertisement → some":
    let (ad, _) = createSignedAdvertisement()
    let encoded = ad.encode().get()
    let regMsg = RegisterMessage(advertisement: encoded)

    let result = validateRegisterMessage(regMsg)
    check result.isSome()

# ---------------------------------------------------------------------------
# processRetryTicket
# ---------------------------------------------------------------------------

suite "Registrar - processRetryTicket":
  test "no ticket present: returns t_wait unchanged":
    let disco = createTestDisco()
    let (ad, _) = createSignedAdvertisement()
    let encoded = ad.encode().get()
    let regMsg = RegisterMessage(advertisement: encoded, ticket: Opt.none(Ticket))

    let tRemaining = disco.processRetryTicket(regMsg, ad, 500.0, makeNow())

    check tRemaining == 500.0

  test "ticket with mismatched advertisement bytes: returns t_wait unchanged":
    let disco = createTestDisco()
    let (ad, _) = createSignedAdvertisement()
    let encoded = ad.encode().get()

    var ticket = Ticket(
      advertisement: @[0xFF.byte], # wrong bytes
      tInit: 1000,
      tMod: 1000,
      tWaitFor: 300,
      signature: @[],
    )
    let _ = ticket.sign(disco.switch.peerInfo.privateKey)
    let regMsg = RegisterMessage(advertisement: encoded, ticket: Opt.some(ticket))

    let tRemaining = disco.processRetryTicket(regMsg, ad, 500.0, makeNow())

    check tRemaining == 500.0

  test "ticket with invalid signature: returns t_wait unchanged":
    let disco = createTestDisco()
    let (ad, _) = createSignedAdvertisement()
    let encoded = ad.encode().get()

    let ticket = Ticket(
      advertisement: encoded,
      tInit: 1000,
      tMod: 1000,
      tWaitFor: 300,
      signature: @[0xBA.byte, 0xAD.byte], # garbage signature
    )
    let regMsg = RegisterMessage(advertisement: encoded, ticket: Opt.some(ticket))

    let tRemaining = disco.processRetryTicket(regMsg, ad, 500.0, makeNow())

    check tRemaining == 500.0

  test "ticket submitted too early: returns t_wait unchanged":
    let disco = createTestDisco()
    let (ad, _) = createSignedAdvertisement()
    let encoded = ad.encode().get()

    let tMod: uint64 = 2000
    let tWaitFor: uint32 = 300
    # Window opens at 2300, we submit at 1000 (too early)
    var ticket = Ticket(
      advertisement: encoded,
      tInit: 1000,
      tMod: tMod,
      tWaitFor: tWaitFor,
      signature: @[],
    )
    let _ = ticket.sign(disco.switch.peerInfo.privateKey)
    let regMsg = RegisterMessage(advertisement: encoded, ticket: Opt.some(ticket))

    let tRemaining = disco.processRetryTicket(regMsg, ad, 500.0, 1000) # now=1000

    check tRemaining == 500.0

  test "valid ticket within window: returns reduced remaining time":
    let disco = createTestDisco()
    let (ad, _) = createSignedAdvertisement()
    let encoded = ad.encode().get()

    let tInit: uint64 = 1000
    let tMod: uint64 = 1000
    let tWaitFor: uint32 = 300
    # Window opens at 1300; submit at 1300 (exactly on time)
    let now: uint64 = 1300

    var ticket = Ticket(
      advertisement: encoded,
      tInit: tInit,
      tMod: tMod,
      tWaitFor: tWaitFor,
      signature: @[],
    )
    let _ = ticket.sign(disco.switch.peerInfo.privateKey)
    let regMsg = RegisterMessage(advertisement: encoded, ticket: Opt.some(ticket))

    let tRemaining = disco.processRetryTicket(regMsg, ad, 500.0, now)
    # t_remaining = t_wait - (now - t_init) = 500 - (1300 - 1000) = 200
    check abs(tRemaining - 200.0) < 1.0

# ---------------------------------------------------------------------------
# Ticket signing / tamper resistance
# ---------------------------------------------------------------------------

suite "Registrar - ticket signing":
  test "valid ticket verifies with correct public key":
    let disco = createTestDisco()
    let (ad, _) = createSignedAdvertisement()
    let encoded = ad.encode().get()

    var ticket = Ticket(
      advertisement: encoded, tInit: 1000, tMod: 1200, tWaitFor: 300, signature: @[]
    )
    let signRes = ticket.sign(disco.switch.peerInfo.privateKey)
    check signRes.isOk()

    let pubKey = disco.switch.peerInfo.privateKey.getPublicKey().get()
    check ticket.verify(pubKey)

  test "tampered t_wait_for invalidates signature":
    let disco = createTestDisco()
    let (ad, _) = createSignedAdvertisement()
    let encoded = ad.encode().get()

    var ticket = Ticket(
      advertisement: encoded,
      tInit: 1000,
      tMod: 1200,
      tWaitFor: 300,
      signature: @[],
    )
    discard ticket.sign(disco.switch.peerInfo.privateKey)
    ticket.tWaitFor = 301 # tamper after signing

    let pubKey = disco.switch.peerInfo.privateKey.getPublicKey().get()
    check not ticket.verify(pubKey)

  test "tampered t_mod invalidates signature":
    let disco = createTestDisco()
    let (ad, _) = createSignedAdvertisement()
    let encoded = ad.encode().get()

    var ticket = Ticket(
      advertisement: encoded,
      tInit: 1000,
      tMod: 1200,
      tWaitFor: 300,
      signature: @[],
    )
    discard ticket.sign(disco.switch.peerInfo.privateKey)
    ticket.tMod = 9999 # tamper after signing

    let pubKey = disco.switch.peerInfo.privateKey.getPublicKey().get()
    check not ticket.verify(pubKey)

  test "tampered advertisement bytes invalidates signature":
    let disco = createTestDisco()
    let (ad, _) = createSignedAdvertisement()
    let encoded = ad.encode().get()

    var ticket = Ticket(
      advertisement: encoded,
      tInit: 1000,
      tMod: 1200,
      tWaitFor: 300,
      signature: @[],
    )
    discard ticket.sign(disco.switch.peerInfo.privateKey)
    ticket.advertisement[0] = ticket.advertisement[0] xor 0xFF # flip a byte

    let pubKey = disco.switch.peerInfo.privateKey.getPublicKey().get()
    check not ticket.verify(pubKey)

# ---------------------------------------------------------------------------
# Lower-bound: retries cannot reduce effective wait ("ticket grinding")
# ---------------------------------------------------------------------------

suite "Registrar - lower bound prevents wait reduction":
  test "successive retries never yield lower effective wait than the bound":
    # RFC intent: even if cache state improves between retries, the bound
    # prevents an attacker from getting a cheaper ticket by retrying.
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)

    # First call: t=1000, cache empty
    let w1 = registrar.waitingTime(discoConf, ad, 1000, serviceId, 1000)
    updateLowerBounds(registrar, serviceId, ad, w1, 1000)

    # Second call at t=1100 — even with empty cache, bound enforces minimum
    let w2 = registrar.waitingTime(discoConf, ad, 1000, serviceId, 1100)

    # RFC invariant: w2 >= w1 - (t2 - t1)
    check w2 >= w1 - 100.0

    # Third call at t=1200
    updateLowerBounds(registrar, serviceId, ad, w2, 1100)
    let w3 = registrar.waitingTime(discoConf, ad, 1000, serviceId, 1200)
    check w3 >= w2 - 100.0

# ===========================================================================
# INTEGRATION TESTS
# ===========================================================================

suite "Registrar - acceptAdvertisement (integration)":
  test "first advertisement: added to cache and IP tree":
    waitFor:
      proc test() {.async.} =
        let disco = createTestDisco()
        let conn = createTestConnection()
        let (ad, _) = createSignedAdvertisement()
        let serviceId = makeServiceId()
        let now = makeNow()

        await disco.acceptAdvertisement(serviceId, ad, now, @[], conn)

        check disco.registrar.cache.getOrDefault(serviceId, @[]).len == 1
        check disco.registrar.cacheTimestamps.len == 1
        # RFC: admitted ad's IPv4 MUST be added to IP tracking structure
        check disco.registrar.ipTree.root.counter == 1
      test()

  test "duplicate peer: timestamp refreshed, not added twice":
    waitFor:
      proc test() {.async.} =
        let disco = createTestDisco()
        let conn = createTestConnection()
        let (ad, _) = createSignedAdvertisement()
        let serviceId = makeServiceId()
        let t1 = makeNow()

        await disco.acceptAdvertisement(serviceId, ad, t1, @[], conn)
        check disco.registrar.cache.getOrDefault(serviceId, @[]).len == 1

        let t2 = t1 + 100
        await disco.acceptAdvertisement(serviceId, ad, t2, @[], conn)
        # Still one entry, not two
        check disco.registrar.cache.getOrDefault(serviceId, @[]).len == 1
        # Timestamp refreshed
        let adKey = ad.toAdvertisementKey()
        check disco.registrar.cacheTimestamps[adKey] == t2

      test()

  test "different peers same service: both admitted":
    waitFor:
      proc test() {.async.} =
        let disco = createTestDisco()
        let conn = createTestConnection()
        let (ad1, _) = createSignedAdvertisement()
        let (ad2, _) = createSignedAdvertisement()
        let serviceId = makeServiceId()
        let now = makeNow()

        await disco.acceptAdvertisement(serviceId, ad1, now, @[], conn)
        await disco.acceptAdvertisement(serviceId, ad2, now, @[], conn)

        check disco.registrar.cache.getOrDefault(serviceId, @[]).len == 2

      test()

suite "Registrar - GET_ADS response cap (integration)":
  test "response is capped at F_return even when cache has more":
    waitFor:
      proc test() {.async.} =
        let fReturn = 3
        let disco = createTestDisco(fReturn = fReturn)
        let conn = createTestConnection()
        let serviceId = makeServiceId()
        let now = makeNow()

        # Admit fReturn + 2 ads for the same service
        for _ in 0 ..< fReturn + 2:
          let (ad, _) = createSignedAdvertisement(serviceId = serviceId)
          await disco.acceptAdvertisement(serviceId, ad, now, @[], conn)

        # Issue GET_ADS and capture response
        let msg = Message(msgType: MessageType.getAds, key: serviceId)
        let responseConn = createCapturingConnection()
        await disco.handleGetAds(responseConn, msg)

        let response = responseConn.lastMessage()
        check response.getAds.isSome()
        check response.getAds.get().advertisements.len <= fReturn

        check response.getAds.get().advertisements.len <= fReturn

suite "Registrar - REGISTER state machine (integration)":
  test "first attempt with no ticket → WAIT response with signed ticket":
    waitFor:
      proc test() {.async.} =
        let disco = createTestDisco()
        let conn = createCapturingConnection()
        let (ad, _) = createSignedAdvertisement()
        let encoded = ad.encode().get()
        let serviceId = makeServiceId()

        let msg = Message(
          msgType: MessageType.register,
          key: serviceId,
          register: Opt.some(RegisterMessage(advertisement: encoded)),
        )
        await disco.handleRegister(conn, msg)

        let response = conn.lastMessage()
        check response.register.isSome()
        let reg = response.register.get()
        check reg.status.get() == RegistrationStatus.Wait
        check reg.ticket.isSome()
        # Ticket must be signed by this registrar
        let pubKey = disco.switch.peerInfo.privateKey.getPublicKey().get()
        check reg.ticket.get().verify(pubKey)

        check reg.ticket.get().verify(pubKey)

  test "retry within window with valid ticket → CONFIRMED and ad cached":
    waitFor:
      proc test() {.async.} =
        let disco = createTestDisco(advertExpiry = 900.0, safetyParam = 0.0)
        # safetyParam = 0 and empty cache → t_wait = 0 → immediate admission on retry
        let conn = createCapturingConnection()
        let (ad, _) = createSignedAdvertisement()
        let encoded = ad.encode().get()
        let serviceId = makeServiceId()

        # First attempt: get ticket
        let msg1 = Message(
          msgType: MessageType.register,
          key: serviceId,
          register: Opt.some(RegisterMessage(advertisement: encoded)),
        )
        await disco.handleRegister(conn, msg1)
        let ticket = conn.lastMessage().register.get().ticket.get()

        # Retry immediately (t_remaining ≤ 0 because safetyParam=0 → t_wait=0)
        let msg2 = Message(
          msgType: MessageType.register,
          key: serviceId,
          register: Opt.some(
            RegisterMessage(advertisement: encoded, ticket: Opt.some(ticket))
          ),
        )
        await disco.handleRegister(conn, msg2)

        let response = conn.lastMessage()
        check response.register.get().status.get() == RegistrationStatus.Confirmed
        check disco.registrar.cache.getOrDefault(serviceId, @[]).len == 1
      test()

  test "duplicate REGISTER after confirmed → REJECTED":
    waitFor:
      proc test() {.async.} =
        let disco = createTestDisco(safetyParam = 0.0)
        let conn = createCapturingConnection()
        let (ad, _) = createSignedAdvertisement()
        let encoded = ad.encode().get()
        let serviceId = makeServiceId()

        # First pass: admit the ad
        let now = makeNow()
        await disco.acceptAdvertisement(serviceId, ad, now, @[], conn)
        check disco.registrar.cache.getOrDefault(serviceId, @[]).len == 1

        # Second REGISTER for the same ad (already in cache)
        let msg = Message(
          msgType: MessageType.register,
          key: serviceId,
          register: Opt.some(RegisterMessage(advertisement: encoded)),
        )
        await disco.handleRegister(conn, msg)

        let response = conn.lastMessage()
        check response.register.get().status.get() == RegistrationStatus.Rejected
        # Cache must not grow
        check disco.registrar.cache.getOrDefault(serviceId, @[]).len == 1

      test()

  test "retry outside δ window → WAIT (ticket not honoured)":
    waitFor:
      proc test() {.async.} =
        let disco = createTestDisco()
        let conn = createCapturingConnection()
        let (ad, _) = createSignedAdvertisement()
        let encoded = ad.encode().get()
        let serviceId = makeServiceId()

        # First attempt: get ticket
        let msg1 = Message(
          msgType: MessageType.register,
          key: serviceId,
          register: Opt.some(RegisterMessage(advertisement: encoded)),
        )
        await disco.handleRegister(conn, msg1)
        var ticket = conn.lastMessage().register.get().ticket.get()

        # Forge a ticket that places the window far in the past (tMod far back)
        ticket.tMod = 1 # window opened at t=1+tWaitFor, long expired
        discard ticket.sign(disco.switch.peerInfo.privateKey)

        let msg2 = Message(
          msgType: MessageType.register,
          key: serviceId,
          register:
            Opt.some(RegisterMessage(advertisement: encoded, ticket: Opt.some(ticket))),
        )
        await disco.handleRegister(conn, msg2)

        # Ticket not honoured → still WAIT (treated as fresh attempt), not CONFIRMED
        let response = conn.lastMessage()
        check response.register.get().status.get() == RegistrationStatus.Wait
        check disco.registrar.cache.getOrDefault(serviceId, @[]).len == 0

      test()

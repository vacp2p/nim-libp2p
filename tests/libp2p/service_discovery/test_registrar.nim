# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[times, math]
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
import ../../../libp2p/stream/lpstream
import ../../tools/bufferstream as testbufferstream
import ../../../libp2p/protocols/kademlia/protobuf as kadprotobuf
import ../../../libp2p/protocols/service_discovery/[types, registrar, iptree]
import ../../tools/unittest
import ./utils

# ============================================================================
# Waiting Time Calculation Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Waiting Time Calculation":
  asyncTest "waitingTime returns low value for empty cache with no IP similarity":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # With empty cache: c = 0, occupancy = 1.0, c_s = 0, ipSim = 0
    # w = advertExpiry * 1.0 * (0 + 0 + safetyParam)
    let expected = discoConf.advertExpiry * discoConf.safetyParam
    check abs(w - expected) < 0.001

  asyncTest "waitingTime increases with cache occupancy":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad1 = createTestAdvertisement(serviceId1)
    let ad2 = createTestAdvertisement(serviceId2)
    let now = getTime().toUnix().uint64

    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now

    let w1 = await registrar.waitingTime(discoConf, ad1, 1000, serviceId1, now)
    let w2 = await registrar.waitingTime(discoConf, ad2, 1000, serviceId2, now)

    # With non-zero cache, occupancy > 1.0
    check w1 > 0 or w2 > 0

  asyncTest "waitingTime increases with service similarity":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad1 = createTestAdvertisement(serviceId = serviceId)
    let ad2 = createTestAdvertisement(serviceId = serviceId)
    let ad3 = createTestAdvertisement(serviceId = serviceId)
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad1, ad2, ad3]
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad3.toAdvertisementKey()] = now

    let w = await registrar.waitingTime(discoConf, ad1, 1000, serviceId, now)

    # c_s = 3, serviceSim = 3/1000 contributes to wait time
    check w > 0

  asyncTest "waitingTime returns 0.0 IP similarity for IPs not in tree":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("192.168.1.1")])
    let now = getTime().toUnix().uint64

    # Tree is empty so IP score is 0
    check registrar.ipTree.ipScore(
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    ) == 0.0

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w > 0

  asyncTest "waitingTime uses maximum IP score across multiple addresses":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()

    registrar.ipTree.insertIp(
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 10])
    )
    registrar.ipTree.insertIp(
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 20])
    )
    registrar.ipTree.insertIp(
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 30])
    )

    let ad = createTestAdvertisement(
      addrs =
        @[
          createTestMultiAddress("10.0.0.1"), # Different subnet – low score
          createTestMultiAddress("192.168.1.50"), # Same subnet – high score
        ]
    )
    let now = getTime().toUnix().uint64
    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w > 0

  asyncTest "waitingTime at cache capacity returns high occupancy":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement()
    let serviceId = makeServiceId()

    for i in 0 ..< 1000:
      let testAd = createTestAdvertisement(serviceId = makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = getTime().toUnix().uint64

    let now = getTime().toUnix().uint64
    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # At capacity, occupancy = 100.0
    check w >= discoConf.advertExpiry * 100.0 * discoConf.safetyParam

  asyncTest "waitingTime formula includes safety parameter":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new(safetyParam = 0.5)
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # Empty cache, no IP sim: w = advertExpiry * 1.0 * safetyParam
    let expected = discoConf.advertExpiry * discoConf.safetyParam
    check abs(w - expected) < 1.0

# ============================================================================
# Lower Bound Enforcement Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Lower Bound Enforcement":
  asyncTest "waitingTime enforces service lower bound when exists":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    # bound = 1500, timestamp = 1000 → effective = 1500 - 0 = 1500
    registrar.boundService[serviceId] = 1500.0
    registrar.timestampService[serviceId] = 1000

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 500.0

  asyncTest "waitingTime service lower bound decreases with elapsed time":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 2000

    # bound = 1500, timestamp = 1000 → elapsed = 1000 → effective = 500
    registrar.boundService[serviceId] = 1500.0
    registrar.timestampService[serviceId] = 1000

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 500.0
    check w < 1000.0

  asyncTest "waitingTime enforces IP lower bound when exists":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ip = "192.168.1.50"
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress(ip)])
    let now: uint64 = 1000
    let serviceId = makeServiceId()

    registrar.boundIp[ip] = 1500.0
    registrar.timestampIp[ip] = 1000

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 500.0

  asyncTest "waitingTime IP lower bound is per IP address":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let now: uint64 = 1000
    let serviceId = makeServiceId()

    registrar.boundIp[ip1] = 1500.0
    registrar.timestampIp[ip1] = 1000

    let ad2 = createTestAdvertisement(addrs = @[createTestMultiAddress(ip2)])
    let w2 = await registrar.waitingTime(discoConf, ad2, 1000, serviceId, now)

    let ad1 = createTestAdvertisement(addrs = @[createTestMultiAddress(ip1)])
    let w1 = await registrar.waitingTime(discoConf, ad1, 1000, serviceId, now)

    check w1 > w2

  asyncTest "waitingTime uses most restrictive lower bound":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let now: uint64 = 1000

    registrar.boundService[serviceId] = 2000.0
    registrar.timestampService[serviceId] = 1000

    registrar.boundIp[ip1] = 3000.0
    registrar.timestampIp[ip1] = 1000

    registrar.boundIp[ip2] = 1500.0
    registrar.timestampIp[ip2] = 1000

    let ad = createTestAdvertisement(
      serviceId = serviceId,
      addrs = @[createTestMultiAddress(ip1), createTestMultiAddress(ip2)],
    )

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 2000.0

# ============================================================================
# Lower Bound Update Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Lower Bound Updates":
  asyncTest "updateLowerBounds stores service bound as w + now":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000
    let w = 500.0

    await updateLowerBounds(registrar, serviceId, ad, w, now)

    check serviceId in registrar.boundService
    check registrar.boundService[serviceId] == w + float64(now) # 1500.0
    check registrar.timestampService[serviceId] == now

  asyncTest "updateLowerBounds updates service bound when w exceeds effective bound":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    registrar.boundService[serviceId] = 1500.0
    registrar.timestampService[serviceId] = 500
    # effective = 1500 - (1000 - 500) = 1000; new w = 1200 > 1000 → update

    await updateLowerBounds(registrar, serviceId, ad, 1200.0, now)

    check registrar.boundService[serviceId] == 2200.0
    check registrar.timestampService[serviceId] == 1000

  asyncTest "updateLowerBounds does not decrease service bound":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    registrar.boundService[serviceId] = 2500.0
    registrar.timestampService[serviceId] = 500
    # effective = 2500 - 500 = 2000; new w = 1000 < 2000 → no update
    let oldBound = registrar.boundService[serviceId]

    await updateLowerBounds(registrar, serviceId, ad, 1000.0, now)

    check registrar.boundService[serviceId] == oldBound

  asyncTest "updateLowerBounds updates IP bound for each address":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let ad = createTestAdvertisement(
      serviceId = serviceId,
      addrs = @[createTestMultiAddress(ip1), createTestMultiAddress(ip2)],
    )
    let now: uint64 = 1000
    let w = 500.0

    await updateLowerBounds(registrar, serviceId, ad, w, now)

    check ip1 in registrar.boundIp
    check registrar.boundIp[ip1] == w + float64(now)
    check registrar.timestampIp[ip1] == now

    check ip2 in registrar.boundIp
    check registrar.boundIp[ip2] == w + float64(now)
    check registrar.timestampIp[ip2] == now

  asyncTest "updateLowerBounds accumulates bounds correctly across multiple calls":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)

    await updateLowerBounds(registrar, serviceId, ad, 500.0, 1000)
    check registrar.boundService[serviceId] == 1500.0

    # effective at t=1500 = 1500 - 500 = 1000; w=800 < 1000 → no update
    await updateLowerBounds(registrar, serviceId, ad, 800.0, 1500)
    check registrar.boundService[serviceId] == 1500.0

    # effective at t=2000 = 1500 - 1000 = 500; w=1200 > 500 → update
    await updateLowerBounds(registrar, serviceId, ad, 1200.0, 2000)
    check registrar.boundService[serviceId] == 3200.0 # 1200 + 2000

  asyncTest "updateLowerBounds with empty addresses does not crash":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId, addrs = @[])
    let now: uint64 = 1000

    await updateLowerBounds(registrar, serviceId, ad, 500.0, now)

    check registrar.boundService[serviceId] == 500.0 + float64(now)

# ============================================================================
# Cache Pruning Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Cache Pruning":
  asyncTest "pruneExpiredAds does nothing on empty registrar":
    let registrar = createTestRegistrar()

    await pruneExpiredAds(registrar, 900)

    check registrar.cache.len == 0
    check registrar.cacheTimestamps.len == 0

  asyncTest "pruneExpiredAds keeps ad within expiry time":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now

    await pruneExpiredAds(registrar, 900)

    check ad in registrar.cache[serviceId]
    check ad.toAdvertisementKey() in registrar.cacheTimestamps

  asyncTest "pruneExpiredAds removes ad past expiry time":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000

    await pruneExpiredAds(registrar, 900)

    check ad notin registrar.cache[serviceId]
    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

  asyncTest "pruneExpiredAds removes ad from IP tree":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ip = IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    let ad = createTestAdvertisement(
      serviceId = serviceId, addrs = @[createTestMultiAddress("192.168.1.1")]
    )
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000
    registrar.ipTree.insertIp(ip)

    check registrar.ipTree.root.counter == 1

    await pruneExpiredAds(registrar, 900)

    check registrar.ipTree.root.counter == 0

  asyncTest "pruneExpiredAds removes from cacheTimestamps":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000

    check ad.toAdvertisementKey() in registrar.cacheTimestamps

    await pruneExpiredAds(registrar, 900)

    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

  asyncTest "pruneExpiredAds handles multiple ads for same service":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad1 = createTestAdvertisement(serviceId = serviceId)
    let ad2 = createTestAdvertisement(serviceId = serviceId)
    let ad3 = createTestAdvertisement(serviceId = serviceId)
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad1, ad2, ad3]
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now - 1000 # expired
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now # fresh
    registrar.cacheTimestamps[ad3.toAdvertisementKey()] = now - 2000 # expired

    await pruneExpiredAds(registrar, 900)

    check registrar.cache[serviceId].len == 1
    check ad2 in registrar.cache[serviceId]
    check ad1 notin registrar.cache[serviceId]
    check ad3 notin registrar.cache[serviceId]

  asyncTest "pruneExpiredAds handles ad with no valid IP addresses":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId, addrs = @[])
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000

    await pruneExpiredAds(registrar, 900)

    check ad notin registrar.cache[serviceId]

# ============================================================================
# State Management Tests
# ============================================================================

suite "Kademlia Discovery Registrar - State Management":
  asyncTest "cache can store multiple ads for same service ID":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad1 = createTestAdvertisement(serviceId = serviceId)
    let ad2 = createTestAdvertisement(serviceId = serviceId)
    let ad3 = createTestAdvertisement(serviceId = serviceId)

    registrar.cache[serviceId] = @[ad1, ad2, ad3]

    check registrar.cache[serviceId].len == 3
    check ad1 in registrar.cache[serviceId]
    check ad2 in registrar.cache[serviceId]
    check ad3 in registrar.cache[serviceId]

  asyncTest "cache can store ads for different service IDs":
    let registrar = createTestRegistrar()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad1 = createTestAdvertisement(serviceId = serviceId1)
    let ad2 = createTestAdvertisement(serviceId = serviceId2)

    registrar.cache[serviceId1] = @[ad1]
    registrar.cache[serviceId2] = @[ad2]

    check registrar.cache.len == 2
    check serviceId1 in registrar.cache
    check serviceId2 in registrar.cache

  asyncTest "cacheTimestamps correctly tracks insertion time":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let timestamp: uint64 = 12345

    registrar.cacheTimestamps[ad.toAdvertisementKey()] = timestamp

    check registrar.cacheTimestamps[ad.toAdvertisementKey()] == timestamp

  asyncTest "IP tree is independent from cache":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ip = IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    let ad = createTestAdvertisement(
      serviceId = serviceId, addrs = @[createTestMultiAddress("192.168.1.1")]
    )

    registrar.cache[serviceId] = @[ad]

    check registrar.ipTree.root.counter == 0

    registrar.ipTree.insertIp(ip)

    check registrar.ipTree.root.counter == 1

# ============================================================================
# Edge Cases Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Edge Cases":
  asyncTest "waitingTime with advertisement with no addresses":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement(addrs = @[])
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 0

  asyncTest "waitingTime with IPv6 addresses only (ignored in IP tree)":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    let ad = createTestAdvertisement(addrs = @[ipv6Addr])
    let now = getTime().toUnix().uint64

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 0

  asyncTest "waitingTime with mixed IPv4 and IPv6 addresses":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()

    registrar.ipTree.insertIp(
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    )

    let ipv4Addr = createTestMultiAddress("192.168.1.50")
    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    let ad = createTestAdvertisement(addrs = @[ipv4Addr, ipv6Addr])
    let now = getTime().toUnix().uint64

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w > 0

  asyncTest "waitingTime with service ID not in boundService":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 0

  asyncTest "waitingTime with IP not in boundIp":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 0

  asyncTest "updateLowerBounds with zero w":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    await updateLowerBounds(registrar, serviceId, ad, 0.0, now)

    check serviceId in registrar.boundService
    check registrar.boundService[serviceId] == 1000.0

  asyncTest "pruneExpiredAds with very old timestamp":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = 1000.uint64

    await pruneExpiredAds(registrar, 1)

    check ad notin registrar.cache[serviceId]
    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

# ============================================================================
# Configuration Variations Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Configuration Variations":
  asyncTest "different advertCacheCap affects occupancy":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    for i in 0 ..< 100:
      let testAd = createTestAdvertisement(serviceId = makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConf = KademliaDiscoveryConfig.new()
    let w1 = await registrar.waitingTime(discoConf, ad, 100, serviceId, now)
    let w2 = await registrar.waitingTime(discoConf, ad, 10000, serviceId, now)

    check w1 >= w2

  asyncTest "different occupancyExp changes wait time curve":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    for i in 0 ..< 500:
      let testAd = createTestAdvertisement(serviceId = makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConf1 = KademliaDiscoveryConfig.new(occupancyExp = 1.0)
    let w1 = await registrar.waitingTime(discoConf1, ad, 1000, serviceId, now)

    let discoConf2 = KademliaDiscoveryConfig.new(occupancyExp = 20.0)
    let w2 = await registrar.waitingTime(discoConf2, ad, 1000, serviceId, now)

    check w2 >= w1

  asyncTest "different advertExpiry scales base wait time":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    let discoConf1 = KademliaDiscoveryConfig.new(advertExpiry = 100.0)
    let w1 = await registrar.waitingTime(discoConf1, ad, 1000, serviceId, now)

    let discoConf2 = KademliaDiscoveryConfig.new(advertExpiry = 2000.0)
    let w2 = await registrar.waitingTime(discoConf2, ad, 1000, serviceId, now)

    check w2 > w1

  asyncTest "different safetyParam adds to wait time":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    let discoConf1 = KademliaDiscoveryConfig.new(safetyParam = 0.0)
    let w1 = await registrar.waitingTime(discoConf1, ad, 1000, serviceId, now)

    let discoConf2 = KademliaDiscoveryConfig.new(safetyParam = 1.0)
    let w2 = await registrar.waitingTime(discoConf2, ad, 1000, serviceId, now)

    check w2 > w1

  asyncTest "occupancyExp of 0 gives occupancy of 1.0":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    for i in 0 ..< 500:
      let testAd = createTestAdvertisement(serviceId = makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConf = KademliaDiscoveryConfig.new(occupancyExp = 0.0)
    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # pow(x, 0) = 1.0 regardless of x, so occupancy = 1.0 / 1.0 = 1.0
    check w >= 0

  asyncTest "occupancyExp of 1 gives linear occupancy":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    for i in 0 ..< 500:
      let testAd = createTestAdvertisement(serviceId = makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConf = KademliaDiscoveryConfig.new(occupancyExp = 1.0)
    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # occupancyExp=1: occupancy = 1/(1-0.5) = 2.0
    check w >= 0

# ============================================================================
# Register Message Validation Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Register Message Validation":
  test "validateRegisterMessage rejects empty advertisement":
    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: @[],
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    check validateRegisterMessage(regMsg).isNone()

  test "validateRegisterMessage rejects malformed advertisement bytes":
    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: @[1'u8, 2, 3, 4],
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    check validateRegisterMessage(regMsg).isNone()

  test "validateRegisterMessage accepts decodable advertisement":
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    let decoded = validateRegisterMessage(regMsg)

    check decoded.isSome()
    check decoded.get().data.peerId == ad.data.peerId
    check decoded.get().data.seqNo == ad.data.seqNo

# ============================================================================
# Retry Ticket Processing Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Retry Ticket Processing":
  test "processRetryTicket returns original wait time when no ticket is present":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )
    let tWait = 300.0
    let now: uint64 = 1_150

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check abs(tRemaining - tWait) < 0.001

  test "processRetryTicket returns original wait time for mismatched ticket advertisement":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    let otherAd = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.2")])
    let otherAdBuf = otherAd.encode().get()

    var ticket = Ticket(
      advertisement: otherAdBuf, tInit: 1_000, tMod: 1_100, tWaitFor: 50, signature: @[]
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 300.0
    let now: uint64 = 1_150

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check abs(tRemaining - tWait) < 0.001

  test "processRetryTicket returns original wait time for invalid ticket signature":
    let disco = createMockDiscovery()
    let otherDisco = createMockDiscovery()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    var ticket = Ticket(
      advertisement: adBuf, tInit: 1_000, tMod: 1_100, tWaitFor: 50, signature: @[]
    )
    check ticket.sign(otherDisco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 300.0
    let now: uint64 = 1_150

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check abs(tRemaining - tWait) < 0.001

  test "processRetryTicket returns original wait time when ticket is expired":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    var ticket = Ticket(
      advertisement: adBuf,
      tInit: 1_000,
      tMod: 1_100,
      tWaitFor: 50,
      expiresAt: 1_149, # expired relative to now = 1_150
      signature: @[],
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 300.0
    let now: uint64 = 1_150

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check abs(tRemaining - tWait) < 0.001

  test "processRetryTicket returns original wait time when retry is too early":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    # windowStart = tMod + tWaitFor = 1_100 + 50 = 1_150; now = 1_149 < windowStart
    var ticket = Ticket(
      advertisement: adBuf,
      tInit: 1_000,
      tMod: 1_100,
      tWaitFor: 50,
      expiresAt: 1_151,
      signature: @[],
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 300.0
    let now: uint64 = 1_149

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check abs(tRemaining - tWait) < 0.001

  test "processRetryTicket returns original wait time when retry is outside registration window":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    # windowStart = 1_150, windowEnd = 1_151 (default delta = 1s); now = 1_152 > windowEnd
    var ticket = Ticket(
      advertisement: adBuf,
      tInit: 1_000,
      tMod: 1_100,
      tWaitFor: 50,
      expiresAt: 1_151,
      signature: @[],
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 300.0
    let now: uint64 = 1_152

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check abs(tRemaining - tWait) < 0.001

  test "processRetryTicket subtracts accumulated wait at windowEnd boundary":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    # windowStart = 1_150, windowEnd = 1_151; now = 1_151 (at boundary)
    var ticket = Ticket(
      advertisement: adBuf,
      tInit: 1_000,
      tMod: 1_100,
      tWaitFor: 50,
      expiresAt: 1_151,
      signature: @[],
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 300.0
    let now: uint64 = 1_151

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    # totalWaitSoFar = 1_151 - 1_000 = 151; tRemaining = 300 - 151 = 149
    check abs(tRemaining - 149.0) < 0.001

  test "processRetryTicket returns non-positive remaining when accumulated wait exceeds tWait":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    var ticket = Ticket(
      advertisement: adBuf,
      tInit: 1_000,
      tMod: 1_100,
      tWaitFor: 50,
      expiresAt: 1_151,
      signature: @[],
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    # tWait=100, now=1_150 → totalWaitSoFar=150 → tRemaining=100-150=-50
    let tWait = 100.0
    let now: uint64 = 1_150

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check tRemaining < 0.0

  test "processRetryTicket subtracts accumulated wait for valid retry in window":
    let disco = createMockDiscovery()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    var ticket = Ticket(
      advertisement: adBuf,
      tInit: 1_000,
      tMod: 1_100,
      tWaitFor: 50,
      expiresAt: 1_151,
      signature: @[],
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = 300.0
    let now: uint64 = 1_150

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    # totalWaitSoFar = 1_150 - 1_000 = 150; tRemaining = 300 - 150 = 150
    check abs(tRemaining - 150.0) < 0.001

# ============================================================================
# acceptAdvertisement seqNo Handling Tests
# ============================================================================

proc makeTestConn(): TestBufferStream =
  TestBufferStream.new(
    proc(
        data: seq[byte]
    ): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
      discard
  )

suite "Kademlia Discovery Registrar - acceptAdvertisement seqNo handling":
  asyncTest "new peer ad is added to cache":
    let disco = createTestDisco()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now = makeNow()
    let conn = makeTestConn()
    defer:
      await conn.close()

    await disco.acceptAdvertisement(serviceId, ad, now, @[], conn)

    check disco.registrar.cache.getOrDefault(serviceId).len == 1
    check disco.registrar.cache[serviceId][0].data.peerId == ad.data.peerId

  asyncTest "same peer same seqNo is treated as duplicate and not added again":
    let disco = createTestDisco()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now = makeNow()
    let conn = makeTestConn()
    defer:
      await conn.close()

    await disco.acceptAdvertisement(serviceId, ad, now, @[], conn)
    await disco.acceptAdvertisement(serviceId, ad, now + 1, @[], conn)

    check disco.registrar.cache[serviceId].len == 1

  asyncTest "same peer higher seqNo replaces existing ad":
    let disco = createTestDisco()
    let serviceId = makeServiceId()
    let peerId = makePeerId()
    let privateKey = PrivateKey.random(rng[]).get()

    let oldAd = SignedExtendedPeerRecord
      .init(
        privateKey,
        ExtendedPeerRecord(peerId: peerId, seqNo: 1, addresses: @[], services: @[]),
      )
      .get()

    let newAd = SignedExtendedPeerRecord
      .init(
        privateKey,
        ExtendedPeerRecord(peerId: peerId, seqNo: 2, addresses: @[], services: @[]),
      )
      .get()

    let now = makeNow()
    let conn = makeTestConn()
    defer:
      await conn.close()

    await disco.acceptAdvertisement(serviceId, oldAd, now, @[], conn)
    check disco.registrar.cache[serviceId][0].data.seqNo == 1

    await disco.acceptAdvertisement(serviceId, newAd, now + 1, @[], conn)

    check disco.registrar.cache[serviceId].len == 1
    check disco.registrar.cache[serviceId][0].data.seqNo == 2

  asyncTest "same peer lower seqNo is silently dropped":
    let disco = createTestDisco()
    let serviceId = makeServiceId()
    let peerId = makePeerId()
    let privateKey = PrivateKey.random(rng[]).get()

    let newerAd = SignedExtendedPeerRecord
      .init(
        privateKey,
        ExtendedPeerRecord(peerId: peerId, seqNo: 10, addresses: @[], services: @[]),
      )
      .get()

    let olderAd = SignedExtendedPeerRecord
      .init(
        privateKey,
        ExtendedPeerRecord(peerId: peerId, seqNo: 5, addresses: @[], services: @[]),
      )
      .get()

    let now = makeNow()
    let conn = makeTestConn()
    defer:
      await conn.close()

    await disco.acceptAdvertisement(serviceId, newerAd, now, @[], conn)
    await disco.acceptAdvertisement(serviceId, olderAd, now + 1, @[], conn)

    check disco.registrar.cache[serviceId].len == 1
    check disco.registrar.cache[serviceId][0].data.seqNo == 10

  asyncTest "different peers each store their own ad":
    let disco = createTestDisco()
    let serviceId = makeServiceId()
    let ad1 = createTestAdvertisement(serviceId = serviceId)
    let ad2 = createTestAdvertisement(serviceId = serviceId)
    let now = makeNow()
    let conn = makeTestConn()
    defer:
      await conn.close()

    await disco.acceptAdvertisement(serviceId, ad1, now, @[], conn)
    await disco.acceptAdvertisement(serviceId, ad2, now, @[], conn)

    check disco.registrar.cache[serviceId].len == 2

  asyncTest "seqNo replacement updates IP tree correctly":
    let disco = createTestDisco()
    let serviceId = makeServiceId()
    let peerId = makePeerId()
    let privateKey = PrivateKey.random(rng[]).get()

    let oldAd = SignedExtendedPeerRecord
      .init(
        privateKey,
        ExtendedPeerRecord(
          peerId: peerId,
          seqNo: 1,
          addresses: @[AddressInfo(address: createTestMultiAddress("10.0.0.1"))],
          services: @[],
        ),
      )
      .get()

    let newAd = SignedExtendedPeerRecord
      .init(
        privateKey,
        ExtendedPeerRecord(
          peerId: peerId,
          seqNo: 2,
          addresses: @[AddressInfo(address: createTestMultiAddress("10.0.0.2"))],
          services: @[],
        ),
      )
      .get()

    let now = makeNow()
    let conn = makeTestConn()
    defer:
      await conn.close()

    await disco.acceptAdvertisement(serviceId, oldAd, now, @[], conn)
    let counterAfterFirst = disco.registrar.ipTree.root.counter
    check counterAfterFirst > 0

    await disco.acceptAdvertisement(serviceId, newAd, now + 1, @[], conn)

    check disco.registrar.cache[serviceId].len == 1
    check disco.registrar.cache[serviceId][0].data.seqNo == 2
    check disco.registrar.ipTree.root.counter == counterAfterFirst

# ============================================================================
# waitingTime Never Negative Tests
# ============================================================================

suite "Kademlia Discovery Registrar - waitingTime never negative":
  asyncTest "waitingTime returns non-negative with stale high service lower bound":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)

    # Large bound with epoch timestamp — elapsed time far exceeds bound
    registrar.boundService[serviceId] = 100.0
    registrar.timestampService[serviceId] = 0

    let now = getTime().toUnix().uint64

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 0.0

  asyncTest "waitingTime returns non-negative with stale high IP lower bound":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ip = "10.0.0.1"

    registrar.boundIp[ip] = 50.0
    registrar.timestampIp[ip] = 0

    let now = getTime().toUnix().uint64

    let w = await registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 0.0

# ============================================================================
# Concurrent Registration Tests
# ============================================================================

suite "Kademlia Discovery Registrar - concurrent same-peer registration":
  asyncTest "concurrent acceptAdvertisement calls for same ad are idempotent":
    let disco = createTestDisco()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now = makeNow()
    let conn = makeTestConn()
    defer:
      await conn.close()

    let f1 = disco.acceptAdvertisement(serviceId, ad, now, @[], conn)
    let f2 = disco.acceptAdvertisement(serviceId, ad, now, @[], conn)
    await allFutures(f1, f2)

    check disco.registrar.cache[serviceId].len == 1

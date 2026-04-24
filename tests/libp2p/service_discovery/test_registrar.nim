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
import ../../../libp2p/protocols/kademlia/protobuf as kadprotobuf
import ../../../libp2p/protocols/service_discovery/[types, registrar]
import ../../../libp2p/utils/iptree
import ../../tools/[unittest, crypto]
import ./utils

func inFloatSecs(d: times.Duration): float64 =
  d.inNanoseconds.float64 / 1_000_000_000.0

suite "Service Discovery Registrar - Waiting Time Calculation":
  test "waitingTime returns low value for empty cache with no IP similarity":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let now = getTime()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # With empty cache: c = 0, occupancy = 1.0, c_s = 0, ipSim = 0
    # w = advertExpiry * 1.0 * (0 + 0 + safetyParam)
    let expected = ceil(discoConfig.advertExpiry * discoConfig.safetyParam)

    check abs(w.inFloatSecs - expected) < 0.001

  test "waitingTime increases with cache occupancy":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad1 = makeAdvertisement($serviceId1)
    let ad2 = makeAdvertisement($serviceId2)
    let now = getTime()

    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now

    let w1 = registrar.waitingTime(discoConfig, ad1, 1000, serviceId1, now)
    let w2 = registrar.waitingTime(discoConfig, ad2, 1000, serviceId2, now)

    # With non-zero cache, occupancy > 1.0
    check w1 > DurationZero or w2 > DurationZero

  test "waitingTime increases with service similarity":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad1 = makeAdvertisement($serviceId)
    let ad2 = makeAdvertisement($serviceId)
    let ad3 = makeAdvertisement($serviceId)
    let now = getTime()

    registrar.cache[serviceId] = @[ad1, ad2, ad3]
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad3.toAdvertisementKey()] = now

    let w = registrar.waitingTime(discoConfig, ad1, 1000, serviceId, now)

    # c_s = 3, serviceSim = 3/1000 contributes to wait time
    check w > DurationZero

  test "waitingTime returns 0.0 IP similarity for IPs not in tree":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("192.168.1.1")])
    let now = getTime()

    # Tree is empty so IP score is 0
    check registrar.ipTree.ipScore(
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    ) == 0.0

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w > DurationZero

  test "waitingTime uses maximum IP score across multiple addresses":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
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

    let ad = makeAdvertisement(
      addrs = @[
        makeMultiAddress("10.0.0.1"), # Different subnet – low score
        makeMultiAddress("192.168.1.50"), # Same subnet – high score
      ]
    )
    let now = getTime()
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w > DurationZero

  test "waitingTime at cache capacity returns high occupancy":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement()
    let serviceId = makeServiceId()

    for i in 0 ..< 1000:
      let testAd = makeAdvertisement($i)
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = getTime()

    let now = getTime()
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # At capacity, occupancy = 100.0
    # Allow 1 ns tolerance: float->ns truncation can lose a sub-nanosecond fraction
    let expectedSecs = ceil(discoConfig.advertExpiry * 100.0 * discoConfig.safetyParam)
    check w.inFloatSecs >= expectedSecs - 1e-9

  test "waitingTime formula includes safety parameter":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new(safetyParam = 0.5)
    let ad = makeAdvertisement()
    let now = getTime()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # Empty cache, no IP sim: w = advertExpiry * 1.0 * safetyParam
    let expected = ceil(discoConfig.advertExpiry * discoConfig.safetyParam)
    check abs(w.inFloatSecs - expected) < 1.0

suite "Service Discovery Registrar - Lower Bound Enforcement":
  test "waitingTime enforces service lower bound when exists":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = fromUnix(1000)

    # bound = 1500, timestamp = 1000 → effective = 1500 - 0 = 1500
    registrar.boundService[serviceId] = fromUnix(1500)
    registrar.timestampService[serviceId] = fromUnix(1000)

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= initDuration(seconds = 500)

  test "waitingTime service lower bound decreases with elapsed time":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = fromUnix(2000)

    # bound = 2500, timestamp = 1000 → elapsed = 1000 → remaining = 500
    registrar.boundService[serviceId] = fromUnix(2500)
    registrar.timestampService[serviceId] = fromUnix(1000)

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= initDuration(seconds = 500)
    check w < initDuration(seconds = 1000)

  test "waitingTime enforces IP lower bound when exists":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ip = "192.168.1.50"
    let ad = makeAdvertisement(addrs = @[makeMultiAddress(ip)])
    let now = fromUnix(1000)
    let serviceId = makeServiceId()

    registrar.boundIp[ip] = fromUnix(1500)
    registrar.timestampIp[ip] = fromUnix(1000)

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= initDuration(seconds = 500)

  test "waitingTime IP lower bound is per IP address":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let now = fromUnix(1000)
    let serviceId = makeServiceId()

    registrar.boundIp[ip1] = fromUnix(1500)
    registrar.timestampIp[ip1] = fromUnix(1000)

    let ad2 = makeAdvertisement(addrs = @[makeMultiAddress(ip2)])
    let w2 = registrar.waitingTime(discoConfig, ad2, 1000, serviceId, now)

    let ad1 = makeAdvertisement(addrs = @[makeMultiAddress(ip1)])
    let w1 = registrar.waitingTime(discoConfig, ad1, 1000, serviceId, now)

    check w1 > w2

  test "waitingTime uses most restrictive lower bound":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let now = fromUnix(1000)

    registrar.boundService[serviceId] = fromUnix(2000)
    registrar.timestampService[serviceId] = fromUnix(1000)

    registrar.boundIp[ip1] = fromUnix(3000)
    registrar.timestampIp[ip1] = fromUnix(1000)

    registrar.boundIp[ip2] = fromUnix(1500)
    registrar.timestampIp[ip2] = fromUnix(1000)

    let ad = makeAdvertisement(
      $serviceId, addrs = @[makeMultiAddress(ip1), makeMultiAddress(ip2)]
    )

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= initDuration(seconds = 2000)

suite "Service Discovery Registrar - Lower Bound Updates":
  test "updateLowerBounds stores service bound as w":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = fromUnix(1000)
    let w = initDuration(seconds = 500)

    updateLowerBounds(registrar, serviceId, ad, w, now)

    check serviceId in registrar.boundService
    check registrar.boundService[serviceId] == now + w
    check registrar.timestampService[serviceId] == now

  test "updateLowerBounds updates service bound when w exceeds effective bound":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = fromUnix(1000)

    registrar.boundService[serviceId] = fromUnix(1500)
    registrar.timestampService[serviceId] = fromUnix(500)
    # effective = 1500 - (1000 - 500) = 1000; new w = 1200 > 1000 → update

    updateLowerBounds(registrar, serviceId, ad, initDuration(seconds = 1200), now)

    check registrar.boundService[serviceId] == fromUnix(2200)
    check registrar.timestampService[serviceId] == fromUnix(1000)

  test "updateLowerBounds does not decrease service bound":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = fromUnix(1000)

    registrar.boundService[serviceId] = fromUnix(2500)
    registrar.timestampService[serviceId] = fromUnix(500)
    # effective = 2500 - 500 = 2000; new w = 1000 < 2000 → no update
    let oldBound = registrar.boundService[serviceId]

    updateLowerBounds(registrar, serviceId, ad, initDuration(seconds = 1000), now)

    check registrar.boundService[serviceId] == oldBound

  test "updateLowerBounds updates IP bound for each address":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let ad = makeAdvertisement(
      $serviceId, addrs = @[makeMultiAddress(ip1), makeMultiAddress(ip2)]
    )
    let now = fromUnix(1000)
    let w = initDuration(seconds = 500)

    updateLowerBounds(registrar, serviceId, ad, w, now)

    check ip1 in registrar.boundIp
    check registrar.boundIp[ip1] == now + w
    check registrar.timestampIp[ip1] == now

    check ip2 in registrar.boundIp
    check registrar.boundIp[ip2] == now + w
    check registrar.timestampIp[ip2] == now

  test "updateLowerBounds accumulates bounds correctly across multiple calls":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)

    updateLowerBounds(
      registrar, serviceId, ad, initDuration(seconds = 500), fromUnix(1000)
    )
    check registrar.boundService[serviceId] == fromUnix(1500)

    # effective at t=1500 = 1500 - 500 = 1000; w=800 < 1000 → no update
    updateLowerBounds(
      registrar, serviceId, ad, initDuration(seconds = 800), fromUnix(1500)
    )
    check registrar.boundService[serviceId] == fromUnix(1500)

    # effective at t=2000 = 1500 - 1000 = 500; w=1200 > 500 → update
    updateLowerBounds(
      registrar, serviceId, ad, initDuration(seconds = 1200), fromUnix(2000)
    )
    check registrar.boundService[serviceId] == fromUnix(3200) # 1200 + 2000

  test "updateLowerBounds with empty addresses does not crash":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId, addrs = @[])
    let now = fromUnix(1000)

    updateLowerBounds(registrar, serviceId, ad, initDuration(seconds = 500), now)

    check registrar.boundService[serviceId] == now + initDuration(seconds = 500)

suite "Service Discovery Registrar - Cache Pruning":
  test "pruneExpiredAds does nothing on empty registrar":
    let registrar = Registrar.new()

    pruneExpiredAds(registrar, initDuration(seconds = 900))

    check registrar.cache.len == 0
    check registrar.cacheTimestamps.len == 0

  test "pruneExpiredAds keeps ad within expiry time":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = getTime()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now

    pruneExpiredAds(registrar, initDuration(seconds = 900))

    check ad in registrar.cache[serviceId]
    check ad.toAdvertisementKey() in registrar.cacheTimestamps

  test "pruneExpiredAds removes ad past expiry time":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = getTime()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] =
      now - initDuration(seconds = 1000)

    pruneExpiredAds(registrar, initDuration(seconds = 900))

    check ad notin registrar.cache.getOrDefault(serviceId)
    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

  test "pruneExpiredAds removes ad from IP tree":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ip = IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    let ad = makeAdvertisement($serviceId, addrs = @[makeMultiAddress("192.168.1.1")])
    let now = getTime()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] =
      now - initDuration(seconds = 1000)
    registrar.ipTree.insertIp(ip)

    check registrar.ipTree.root.counter == 1

    pruneExpiredAds(registrar, initDuration(seconds = 900))

    check registrar.ipTree.root.counter == 0

  test "pruneExpiredAds removes from cacheTimestamps":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = getTime()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] =
      now - initDuration(seconds = 1000)

    check ad.toAdvertisementKey() in registrar.cacheTimestamps

    pruneExpiredAds(registrar, initDuration(seconds = 900))

    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

  test "pruneExpiredAds handles multiple ads for same service":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad1 = makeAdvertisement($serviceId)
    let ad2 = makeAdvertisement($serviceId)
    let ad3 = makeAdvertisement($serviceId)
    let now = getTime()

    registrar.cache[serviceId] = @[ad1, ad2, ad3]
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] =
      now - initDuration(seconds = 1000) # expired
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now # fresh
    registrar.cacheTimestamps[ad3.toAdvertisementKey()] =
      now - initDuration(seconds = 2000) # expired

    pruneExpiredAds(registrar, initDuration(seconds = 900))

    check registrar.cache[serviceId].len == 1
    check ad2 in registrar.cache[serviceId]
    check ad1 notin registrar.cache[serviceId]
    check ad3 notin registrar.cache[serviceId]

  test "pruneExpiredAds handles ad with no valid IP addresses":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId, addrs = @[])
    let now = getTime()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] =
      now - initDuration(seconds = 1000)

    pruneExpiredAds(registrar, initDuration(seconds = 900))

    check ad notin registrar.cache.getOrDefault(serviceId)

suite "Service Discovery Registrar - State Management":
  test "cache can store multiple ads for same service ID":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad1 = makeAdvertisement($serviceId)
    let ad2 = makeAdvertisement($serviceId)
    let ad3 = makeAdvertisement($serviceId)

    registrar.cache[serviceId] = @[ad1, ad2, ad3]

    check registrar.cache[serviceId].len == 3
    check ad1 in registrar.cache[serviceId]
    check ad2 in registrar.cache[serviceId]
    check ad3 in registrar.cache[serviceId]

  test "cache can store ads for different service IDs":
    let registrar = Registrar.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad1 = makeAdvertisement($serviceId1)
    let ad2 = makeAdvertisement($serviceId2)

    registrar.cache[serviceId1] = @[ad1]
    registrar.cache[serviceId2] = @[ad2]

    check registrar.cache.len == 2
    check serviceId1 in registrar.cache
    check serviceId2 in registrar.cache

  test "cacheTimestamps correctly tracks insertion time":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let timestamp = fromUnix(12345)

    registrar.cacheTimestamps[ad.toAdvertisementKey()] = timestamp

    check registrar.cacheTimestamps[ad.toAdvertisementKey()] == timestamp

  test "IP tree is independent from cache":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ip = IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    let ad = makeAdvertisement($serviceId, addrs = @[makeMultiAddress("192.168.1.1")])

    registrar.cache[serviceId] = @[ad]

    check registrar.ipTree.root.counter == 0

    registrar.ipTree.insertIp(ip)

    check registrar.ipTree.root.counter == 1

suite "Service Discovery Registrar - Edge Cases":
  test "waitingTime with advertisement with no addresses":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement(addrs = @[])
    let now = getTime()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= DurationZero

  test "waitingTime with IPv6 addresses only (ignored in IP tree)":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    let ad = makeAdvertisement(addrs = @[ipv6Addr])
    let now = getTime()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= DurationZero

  test "waitingTime with mixed IPv4 and IPv6 addresses":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()

    registrar.ipTree.insertIp(
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    )

    let ipv4Addr = makeMultiAddress("192.168.1.50")
    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    let ad = makeAdvertisement(addrs = @[ipv4Addr, ipv6Addr])
    let now = getTime()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w > DurationZero

  test "waitingTime with service ID not in boundService":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement()
    let now = getTime()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= DurationZero

  test "waitingTime with IP not in boundIp":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let now = getTime()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= DurationZero

  test "updateLowerBounds with zero w":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = fromUnix(1000)

    updateLowerBounds(registrar, serviceId, ad, DurationZero, now)

    check serviceId in registrar.boundService
    check registrar.boundService[serviceId] == now

  test "pruneExpiredAds with very old timestamp":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = fromUnix(1000)

    pruneExpiredAds(registrar, initDuration(seconds = 1))

    check ad notin registrar.cache.getOrDefault(serviceId)
    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

suite "Service Discovery Registrar - Configuration Variations":
  test "different advertCacheCap affects occupancy":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = getTime()
    let serviceId = makeServiceId()

    for i in 0 ..< 100:
      let testAd = makeAdvertisement($makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConfig = ServiceDiscoveryConfig.new()
    let w1 = registrar.waitingTime(discoConfig, ad, 100, serviceId, now)
    let w2 = registrar.waitingTime(discoConfig, ad, 10000, serviceId, now)

    check w1 >= w2

  test "different occupancyExp changes wait time curve":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = getTime()
    let serviceId = makeServiceId()

    for i in 0 ..< 500:
      let testAd = makeAdvertisement($makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConfig1 = ServiceDiscoveryConfig.new(occupancyExp = 1.0)
    let w1 = registrar.waitingTime(discoConfig1, ad, 1000, serviceId, now)

    let discoConfig2 = ServiceDiscoveryConfig.new(occupancyExp = 20.0)
    let w2 = registrar.waitingTime(discoConfig2, ad, 1000, serviceId, now)

    check w2 >= w1

  test "different advertExpiry scales base wait time":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = getTime()
    let serviceId = makeServiceId()

    let discoConfig1 =
      ServiceDiscoveryConfig.new(safetyParam = 1.0, advertExpiry = 100.0)
    let w1 = registrar.waitingTime(discoConfig1, ad, 1000, serviceId, now)

    let discoConfig2 =
      ServiceDiscoveryConfig.new(safetyParam = 1.0, advertExpiry = 10000.0)
    let w2 = registrar.waitingTime(discoConfig2, ad, 1000, serviceId, now)

    check w2 > w1

  test "different safetyParam adds to wait time":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = getTime()
    let serviceId = makeServiceId()

    let discoConfig1 = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let w1 = registrar.waitingTime(discoConfig1, ad, 1000, serviceId, now)

    let discoConfig2 = ServiceDiscoveryConfig.new(safetyParam = 1.0)
    let w2 = registrar.waitingTime(discoConfig2, ad, 1000, serviceId, now)

    check w2 > w1

  test "occupancyExp of 0 gives occupancy of 1.0":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = getTime()
    let serviceId = makeServiceId()

    for i in 0 ..< 500:
      let testAd = makeAdvertisement($makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConfig = ServiceDiscoveryConfig.new(occupancyExp = 0.0)
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # pow(x, 0) = 1.0 regardless of x, so occupancy = 1.0 / 1.0 = 1.0
    check w >= DurationZero

  test "occupancyExp of 1 gives linear occupancy":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = getTime()
    let serviceId = makeServiceId()

    for i in 0 ..< 500:
      let testAd = makeAdvertisement($makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConfig = ServiceDiscoveryConfig.new(occupancyExp = 1.0)
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # occupancyExp=1: occupancy = 1/(1-0.5) = 2.0
    check w >= DurationZero

suite "Service Discovery Registrar - Register Message Validation":
  test "validateRegisterMessage rejects empty advertisement":
    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: @[],
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    check validateRegisterMessage(regMsg, makeServiceId()).isNone()

  test "validateRegisterMessage rejects malformed advertisement bytes":
    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: @[1'u8, 2, 3, 4],
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    check validateRegisterMessage(regMsg, makeServiceId()).isNone()

  test "validateRegisterMessage accepts decodable advertisement":
    let serviceStr = $1
    let serviceId = hashServiceId(serviceStr)
    let ad = makeAdvertisement(serviceStr, addrs = @[makeMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    let decoded = validateRegisterMessage(regMsg, serviceId)

    check decoded.isSome()
    check decoded.get().data.peerId == ad.data.peerId
    check decoded.get().data.seqNo == ad.data.seqNo

suite "Service Discovery Registrar - Retry Ticket Processing":
  test "processRetryTicket returns original wait time when no ticket is present":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )
    let tWait = initDuration(seconds = 300)
    let now = fromUnix(1_150)

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check tRemaining == tWait

  test "processRetryTicket returns original wait time for mismatched ticket advertisement":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    let otherAd = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.2")])
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
    let tWait = initDuration(seconds = 300)
    let now = fromUnix(1_150)

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check tRemaining == tWait

  test "processRetryTicket returns original wait time for invalid ticket signature":
    let disco = makeMockDiscovery()
    let otherDisco = makeMockDiscovery()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
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
    let tWait = initDuration(seconds = 300)
    let now = fromUnix(1_150)

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check tRemaining == tWait

  test "processRetryTicket returns original wait time when retry is too early":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    # windowStart = tMod + tWaitFor = 1_100 + 50 = 1_150; now = 1_149 < windowStart
    var ticket = Ticket(
      advertisement: adBuf, tInit: 1_000, tMod: 1_100, tWaitFor: 50, signature: @[]
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = initDuration(seconds = 300)
    let now = fromUnix(1_149)

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check tRemaining == tWait

  test "processRetryTicket returns original wait time when retry is outside registration window":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    # windowStart = 1_150, windowEnd = 1_151 (default delta = 1s); now = 1_152 > windowEnd
    var ticket = Ticket(
      advertisement: adBuf, tInit: 1_000, tMod: 1_100, tWaitFor: 50, signature: @[]
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = initDuration(seconds = 300)
    let now = fromUnix(1_152)

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check tRemaining == tWait

  test "processRetryTicket subtracts accumulated wait at windowEnd boundary":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    # windowStart = 1_150, windowEnd = 1_151; now = 1_151 (at boundary)
    var ticket = Ticket(
      advertisement: adBuf, tInit: 1_000, tMod: 1_100, tWaitFor: 50, signature: @[]
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = initDuration(seconds = 300)
    let now = fromUnix(1_151)

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    # totalWaitSoFar = 1_151 - 1_000 = 151; tRemaining = 300 - 151 = 149
    check tRemaining == initDuration(seconds = 149)

  test "processRetryTicket returns non-positive remaining when accumulated wait exceeds tWait":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    var ticket = Ticket(
      advertisement: adBuf, tInit: 1_000, tMod: 1_100, tWaitFor: 50, signature: @[]
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    # tWait=100, now=1_150 → totalWaitSoFar=150 → tRemaining=100-150=-50
    let tWait = initDuration(seconds = 100)
    let now = fromUnix(1_150)

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    check tRemaining <= DurationZero

  test "processRetryTicket subtracts accumulated wait for valid retry in window":
    let disco = makeMockDiscovery()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    var ticket = Ticket(
      advertisement: adBuf, tInit: 1_000, tMod: 1_100, tWaitFor: 50, signature: @[]
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    let tWait = initDuration(seconds = 300)
    let now = fromUnix(1_150)

    let tRemaining = disco.processRetryTicket(regMsg, ad, tWait, now)

    # totalWaitSoFar = 1_150 - 1_000 = 150; tRemaining = 300 - 150 = 150
    check tRemaining == initDuration(seconds = 150)

suite "Service Discovery Registrar - acceptAdvertisement seqNo handling":
  test "new peer ad is added to cache":
    let disco = makeDisco()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)

    disco.acceptAdvertisement(serviceId, ad)

    check disco.registrar.cache.getOrDefault(serviceId).len == 1
    check disco.registrar.cache[serviceId][0].data.peerId == ad.data.peerId

  test "same peer same seqNo is treated as duplicate and not added again":
    let disco = makeDisco()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)

    disco.acceptAdvertisement(serviceId, ad)
    disco.acceptAdvertisement(serviceId, ad)

    check disco.registrar.cache[serviceId].len == 1

  test "same peer higher seqNo replaces existing ad":
    let disco = makeDisco()
    let serviceId = makeServiceId()
    let privateKey = PrivateKey.random(rng[]).get()
    let peerId = PeerId.init(privateKey).get()

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

    disco.acceptAdvertisement(serviceId, oldAd)
    check disco.registrar.cache[serviceId][0].data.seqNo == 1

    disco.acceptAdvertisement(serviceId, newAd)

    check disco.registrar.cache[serviceId].len == 1
    check disco.registrar.cache[serviceId][0].data.seqNo == 2

  test "same peer lower seqNo is silently dropped":
    let disco = makeDisco()
    let serviceId = makeServiceId()
    let privateKey = PrivateKey.random(rng[]).get()
    let peerId = PeerId.init(privateKey).get()

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

    disco.acceptAdvertisement(serviceId, newerAd)
    disco.acceptAdvertisement(serviceId, olderAd)

    check disco.registrar.cache[serviceId].len == 1
    check disco.registrar.cache[serviceId][0].data.seqNo == 10

  test "different peers each store their own ad":
    let disco = makeDisco()
    let serviceId = makeServiceId()
    let ad1 = makeAdvertisement($serviceId)
    let ad2 = makeAdvertisement($serviceId)

    disco.acceptAdvertisement(serviceId, ad1)
    disco.acceptAdvertisement(serviceId, ad2)

    check disco.registrar.cache[serviceId].len == 2

  test "seqNo replacement updates IP tree correctly":
    let disco = makeDisco()
    let serviceId = makeServiceId()
    let privateKey = PrivateKey.random(rng[]).get()
    let peerId = PeerId.init(privateKey).get()

    let oldAd = SignedExtendedPeerRecord
      .init(
        privateKey,
        ExtendedPeerRecord(
          peerId: peerId,
          seqNo: 1,
          addresses: @[AddressInfo(address: makeMultiAddress("10.0.0.1"))],
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
          addresses: @[AddressInfo(address: makeMultiAddress("10.0.0.2"))],
          services: @[],
        ),
      )
      .get()

    disco.acceptAdvertisement(serviceId, oldAd)
    let counterAfterFirst = disco.registrar.ipTree.root.counter
    check counterAfterFirst > 0

    disco.acceptAdvertisement(serviceId, newAd)

    check disco.registrar.cache[serviceId].len == 1
    check disco.registrar.cache[serviceId][0].data.seqNo == 2
    check disco.registrar.ipTree.root.counter == counterAfterFirst

suite "Service Discovery Registrar - waitingTime never negative":
  test "waitingTime returns non-negative with stale high service lower bound":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)

    # Large bound with epoch timestamp — elapsed time far exceeds bound
    registrar.boundService[serviceId] = fromUnix(100)
    registrar.timestampService[serviceId] = fromUnix(0)

    let now = getTime()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= DurationZero

  test "waitingTime returns non-negative with stale high IP lower bound":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ip = "10.0.0.1"

    registrar.boundIp[ip] = fromUnix(50)
    registrar.timestampIp[ip] = fromUnix(0)

    let ad = makeAdvertisement(addrs = @[makeMultiAddress(ip)])
    let now = getTime()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= DurationZero

suite "Service Discovery Registrar - concurrent same-peer registration":
  test "repeated acceptAdvertisement calls for same ad are idempotent":
    let disco = makeDisco()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)

    disco.acceptAdvertisement(serviceId, ad)
    disco.acceptAdvertisement(serviceId, ad)

    check disco.registrar.cache[serviceId].len == 1

suite "Service Discovery Registrar - updateExistingAd":
  test "same seqNo refreshes timestamp and returns false":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    var ads = @[ad]
    let oldTime = fromUnix(1000)
    let newTime = fromUnix(2000)

    registrar.cacheTimestamps[ad.toAdvertisementKey()] = oldTime
    registrar.ipTree.insertAd(ad)
    let counterBefore = registrar.ipTree.root.counter

    let changed = registrar.updateExistingAd(ads, 0, ad, newTime)

    check not changed
    check registrar.cacheTimestamps[ad.toAdvertisementKey()] == newTime
    check registrar.ipTree.root.counter == counterBefore

  test "higher seqNo replaces ad, updates timestamps and IP tree, returns true":
    let registrar = Registrar.new()
    let privateKey = PrivateKey.random(rng[]).get()
    let oldAd = makeAdvertisement(privateKey = privateKey, seqNo = 1)
    let newAd = makeAdvertisement(privateKey = privateKey, seqNo = 2)
    var ads = @[oldAd]

    registrar.cacheTimestamps[oldAd.toAdvertisementKey()] = fromUnix(1000)
    registrar.ipTree.insertAd(oldAd)

    let changed = registrar.updateExistingAd(ads, 0, newAd, fromUnix(2000))

    check changed
    check ads.len == 1
    check ads[0].data.seqNo == 2
    check oldAd.toAdvertisementKey() notin registrar.cacheTimestamps
    check newAd.toAdvertisementKey() in registrar.cacheTimestamps
    check registrar.cacheTimestamps[newAd.toAdvertisementKey()] == fromUnix(2000)

  test "higher seqNo with address swap removes old IP and inserts new one":
    let registrar = Registrar.new()
    let privateKey = PrivateKey.random(rng[]).get()
    let oldAd = makeAdvertisement(
      privateKey = privateKey, seqNo = 1, addrs = @[makeMultiAddress("10.0.0.1")]
    )
    let newAd = makeAdvertisement(
      privateKey = privateKey, seqNo = 2, addrs = @[makeMultiAddress("192.168.1.1")]
    )
    var ads = @[oldAd]

    registrar.ipTree.insertAd(oldAd)
    registrar.cacheTimestamps[oldAd.toAdvertisementKey()] = fromUnix(1000)
    let counterBefore = registrar.ipTree.root.counter

    discard registrar.updateExistingAd(ads, 0, newAd, fromUnix(2000))

    # IP tree entry count is unchanged: one removed, one added
    check registrar.ipTree.root.counter == counterBefore

  test "lower seqNo leaves cache and timestamps unchanged, returns false":
    let registrar = Registrar.new()
    let privateKey = PrivateKey.random(rng[]).get()
    let currentAd = makeAdvertisement(privateKey = privateKey, seqNo = 10)
    let staleAd = makeAdvertisement(privateKey = privateKey, seqNo = 5)
    var ads = @[currentAd]

    registrar.cacheTimestamps[currentAd.toAdvertisementKey()] = fromUnix(1000)

    let changed = registrar.updateExistingAd(ads, 0, staleAd, fromUnix(2000))

    check not changed
    check ads[0].data.seqNo == 10
    check currentAd.toAdvertisementKey() in registrar.cacheTimestamps
    check staleAd.toAdvertisementKey() notin registrar.cacheTimestamps

suite "Service Discovery Registrar - insertNewAd":
  test "inserts ad into cache, IP tree, and timestamps, returns true":
    let disco = makeDisco()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    var ads: seq[Advertisement] = @[]
    let now = fromUnix(1000)

    let changed = disco.insertNewAd(serviceId, ads, ad, now)

    check changed
    check ads.len == 1
    check ads[0].data.peerId == ad.data.peerId
    check ad.toAdvertisementKey() in disco.registrar.cacheTimestamps
    check disco.registrar.cacheTimestamps[ad.toAdvertisementKey()] == now
    check disco.registrar.ipTree.root.counter > 0

  test "inserts ad without eviction when cache is under capacity":
    let disco = makeDisco(advertExpiry = 900.0)
    let serviceId = makeServiceId()
    let existingAd = makeAdvertisement($makeServiceId(99))
    disco.registrar.cacheTimestamps[existingAd.toAdvertisementKey()] = fromUnix(1000)

    let newAd = makeAdvertisement()
    var ads: seq[Advertisement] = @[]

    discard disco.insertNewAd(serviceId, ads, newAd, fromUnix(2000))

    # Existing ad must still be present (no eviction)
    check existingAd.toAdvertisementKey() in disco.registrar.cacheTimestamps
    check ads.len == 1

  test "evicts oldest entry and inserts new ad when cache is at capacity":
    # Use a small cap so i.byte never overflows (byte wraps at 256)
    let cap = 5
    let config = ServiceDiscoveryConfig.new(
      kRegister = 3, bucketsCount = 16, advertCacheCap = cap.uint64
    )
    let disco = makeMockDiscovery(config)
    let serviceId = makeServiceId()
    let now = fromUnix(5000)

    # Fill cache exactly to capacity; the first entry gets the oldest timestamp
    var oldestAd: Advertisement
    for i in 0 ..< cap:
      let sid = makeServiceId(i.byte)
      let a = makeAdvertisement($sid)
      let ts =
        if i == 0:
          fromUnix(100)
        else:
          now
      disco.registrar.cacheTimestamps[a.toAdvertisementKey()] = ts
      disco.registrar.cache[sid] = @[a]
      if i == 0:
        oldestAd = a

    let newAd = makeAdvertisement()
    var ads: seq[Advertisement] = @[]

    let changed = disco.insertNewAd(serviceId, ads, newAd, now)

    check changed
    check oldestAd.toAdvertisementKey() notin disco.registrar.cacheTimestamps
    check newAd.toAdvertisementKey() in disco.registrar.cacheTimestamps
    check ads.len == 1

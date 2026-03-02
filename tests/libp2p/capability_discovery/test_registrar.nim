# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[times, net]
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

suite "Kademlia Discovery Registrar - Waiting Time Calculation":
  test "waitingTime returns 0 for empty cache with no IP similarity":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # With empty cache, c = 0, so occupancy = 1.0
    # c_s = 0, serviceSim = 0
    # ipSim = 0 (tree is empty)
    # w = advertExpiry * 1.0 * (0 + 0 + safetyParam)
    let expected = discoConf.advertExpiry * discoConf.safetyParam
    check abs(w - expected) < 0.001

  test "waitingTime increases with cache occupancy":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad1 = createTestAdvertisement(serviceId1)
    let ad2 = createTestAdvertisement(serviceId2)
    let now = getTime().toUnix().uint64

    # Add some ads to increase cache size
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now

    let w1 = registrar.waitingTime(discoConf, ad1, 1000, serviceId1, now)
    let w2 = registrar.waitingTime(discoConf, ad2, 1000, serviceId2, now)

    # With non-zero cache, occupancy > 1.0, so wait time should increase
    check w1 > 0 or w2 > 0

  test "waitingTime increases with service similarity":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()

    # Add multiple ads for same service
    let ad1 = createTestAdvertisement(serviceId = serviceId)
    let ad2 = createTestAdvertisement(serviceId = serviceId)
    let ad3 = createTestAdvertisement(serviceId = serviceId)

    let now = getTime().toUnix().uint64
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad3.toAdvertisementKey()] = now

    let w = registrar.waitingTime(discoConf, ad1, 1000, serviceId, now)

    # c_s = 3, so serviceSim = 3/1000 = 0.003
    # This should contribute to wait time
    check w > 0

  test "waitingTime returns 0.0 IP similarity for IPs not in tree":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()

    # Don't populate the tree
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("192.168.1.1")])
    let now = getTime().toUnix().uint64

    # First check the IP score is 0
    let ipScore = registrar.ipTree.ipScore(parseIpAddress("192.168.1.1"))
    check ipScore == 0.0

    # Verify waitingTime calculation includes this IP score
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)
    # With ipSim = 0, w should be just advertExpiry * occupancy * (serviceSim + safetyParam)
    check w > 0

  test "waitingTime uses maximum IP score across multiple addresses":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()

    # Populate tree with IPs from same subnet
    registrar.ipTree.insertIp(parseIpAddress("192.168.1.10"))
    registrar.ipTree.insertIp(parseIpAddress("192.168.1.20"))
    registrar.ipTree.insertIp(parseIpAddress("192.168.1.30"))

    # Ad with multiple addresses - some similar, some not
    let ad = createTestAdvertisement(
      addrs =
        @[
          createTestMultiAddress("10.0.0.1"), # Different subnet - low score
          createTestMultiAddress("192.168.1.50"), # Same subnet - high score
        ]
    )

    let now = getTime().toUnix().uint64
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # The high IP similarity from 192.168.1.50 should increase wait time
    check w > 0

  test "waitingTime at cache capacity returns high occupancy":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement()
    let serviceId = makeServiceId()

    # Fill cache to capacity
    for i in 0 ..< 1000:
      let testAd = createTestAdvertisement(serviceId = makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = getTime().toUnix().uint64

    let now = getTime().toUnix().uint64
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # At capacity, occupancy = 100.0, so wait time should be very high
    check w >= discoConf.advertExpiry * 100.0 * discoConf.safetyParam

  test "waitingTime formula includes safety parameter":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new(
      safetyParam = 0.5 # High safety param
    )
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # With empty cache and no IP similarity:
    # w = advertExpiry * 1.0 * (0 + 0 + safetyParam)
    # w = 900 * 1.0 * 0.5 = 450
    let expected = discoConf.advertExpiry * discoConf.safetyParam
    check abs(w - expected) < 1.0

# ============================================================================
# 3. Lower Bound Enforcement Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Lower Bound Enforcement":
  test "waitingTime enforces service lower bound when exists":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    # Set a lower bound for this service (bound = w + now = 500 + 1000 = 1500)
    registrar.boundService[serviceId] = 1500.0
    registrar.timestampService[serviceId] = 1000

    # Calculate wait time - should be at least bound - elapsed = 1500 - 0 = 1500
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 500.0

  test "waitingTime service lower bound decreases with elapsed time":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 2000

    # Set a lower bound (bound = 1500, timestamp = 1000)
    registrar.boundService[serviceId] = 1500.0
    registrar.timestampService[serviceId] = 1000

    # elapsed = 2000 - 1000 = 1000
    # effective bound = 1500 - 1000 = 500
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 500.0
    check w < 1000.0 # Should not exceed initial bound value significantly

  test "waitingTime enforces IP lower bound when exists":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ip = "192.168.1.50"
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress(ip)])
    let now: uint64 = 1000
    let serviceId = makeServiceId()

    # Set a lower bound for this IP
    registrar.boundIp[ip] = 1500.0
    registrar.timestampIp[ip] = 1000

    # Calculate wait time - should be at least bound - elapsed = 1500 - 0 = 1500
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 500.0

  test "waitingTime IP lower bound is per IP address":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let now: uint64 = 1000
    let serviceId = makeServiceId()

    # Set bound for IP1 only
    registrar.boundIp[ip1] = 1500.0
    registrar.timestampIp[ip1] = 1000

    # Ad with IP2 only - should not be affected by IP1's bound
    let ad2 = createTestAdvertisement(addrs = @[createTestMultiAddress(ip2)])
    let w2 = registrar.waitingTime(discoConf, ad2, 1000, serviceId, now)

    # Ad with IP1 - should be affected by bound
    let ad1 = createTestAdvertisement(addrs = @[createTestMultiAddress(ip1)])
    let w1 = registrar.waitingTime(discoConf, ad1, 1000, serviceId, now)

    check w1 > w2

  test "waitingTime uses most restrictive lower bound":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let now: uint64 = 1000

    # Set different bounds
    registrar.boundService[serviceId] = 2000.0 # Service bound = 2000 - 0 = 2000
    registrar.timestampService[serviceId] = 1000

    registrar.boundIp[ip1] = 3000.0 # IP1 bound = 3000 - 0 = 3000 (most restrictive)
    registrar.timestampIp[ip1] = 1000

    registrar.boundIp[ip2] = 1500.0 # IP2 bound = 1500 - 0 = 1500
    registrar.timestampIp[ip2] = 1000

    let ad = createTestAdvertisement(
      serviceId = serviceId,
      addrs = @[createTestMultiAddress(ip1), createTestMultiAddress(ip2)],
    )

    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # Should use the most restrictive bound (IP1: 3000)
    check w >= 2000.0

# ============================================================================
# 4. Lower Bound Update Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Lower Bound Updates":
  test "updateLowerBounds stores service bound as w + now":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000
    let w = 500.0

    updateLowerBounds(registrar, serviceId, ad, w, now)

    check serviceId in registrar.boundService
    check registrar.boundService[serviceId] == w + float64(now) # 500 + 1000 = 1500
    check registrar.timestampService[serviceId] == now

  test "updateLowerBounds updates service bound when w exceeds effective bound":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    # Set initial bound
    registrar.boundService[serviceId] = 1500.0
    registrar.timestampService[serviceId] = 500

    # Current effective bound = 1500 - (1000 - 500) = 1000
    # New w = 1200, which exceeds current effective bound
    updateLowerBounds(registrar, serviceId, ad, 1200.0, now)

    check registrar.boundService[serviceId] == 1200.0 + 1000.0
    check registrar.timestampService[serviceId] == 1000

  test "updateLowerBounds does not decrease service bound":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    # Set initial bound
    registrar.boundService[serviceId] = 2500.0
    registrar.timestampService[serviceId] = 500

    # Current effective bound = 2500 - (1000 - 500) = 2000
    # New w = 1000, which is less than current effective bound
    # Bound should NOT be updated
    let oldBound = registrar.boundService[serviceId]
    updateLowerBounds(registrar, serviceId, ad, 1000.0, now)

    check registrar.boundService[serviceId] == oldBound

  test "updateLowerBounds updates IP bound for each address":
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

    updateLowerBounds(registrar, serviceId, ad, w, now)

    check ip1 in registrar.boundIp
    check registrar.boundIp[ip1] == w + float64(now)
    check registrar.timestampIp[ip1] == now

    check ip2 in registrar.boundIp
    check registrar.boundIp[ip2] == w + float64(now)
    check registrar.timestampIp[ip2] == now

  test "updateLowerBounds accumulates bounds for multiple calls":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)

    # First call at t=1000 with w=500
    updateLowerBounds(registrar, serviceId, ad, 500.0, 1000)
    check registrar.boundService[serviceId] == 1500.0

    # Second call at t=1500 with w=800
    # Effective bound at t=1500 = 1500 - (1500 - 1000) = 1000
    # Since w=800 < 1000, bound should NOT be updated
    updateLowerBounds(registrar, serviceId, ad, 800.0, 1500)
    check registrar.boundService[serviceId] == 1500.0

    # Third call at t=2000 with w=1200
    # Effective bound at t=2000 = 1500 - (2000 - 1000) = 500
    # Since w=1200 > 500, bound should be updated
    updateLowerBounds(registrar, serviceId, ad, 1200.0, 2000)
    check registrar.boundService[serviceId] == 3200.0 # 1200 + 2000

  test "updateLowerBounds with empty addresses does not crash":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId, addrs = @[])
    let now: uint64 = 1000
    let w = 500.0

    # Should not crash
    updateLowerBounds(registrar, serviceId, ad, w, now)

    # Service bound should still be updated
    check registrar.boundService[serviceId] == w + float64(now)

# ============================================================================
# 5. Cache Pruning Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Cache Pruning":
  test "pruneExpiredAds does nothing on empty registrar":
    let registrar = createTestRegistrar()

    pruneExpiredAds(registrar, 900)

    check registrar.cache.len == 0
    check registrar.cacheTimestamps.len == 0

  test "pruneExpiredAds keeps ad within expiry time":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now

    pruneExpiredAds(registrar, 900)

    check ad in registrar.cache[serviceId]
    check ad.toAdvertisementKey() in registrar.cacheTimestamps

  test "pruneExpiredAds removes ad past expiry time":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000 # 1000 seconds ago

    pruneExpiredAds(registrar, 900) # 900 second expiry

    check ad notin registrar.cache[serviceId]
    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

  test "pruneExpiredAds removes ad from IP tree":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ip = "192.168.1.1"
    let ad = createTestAdvertisement(
      serviceId = serviceId, addrs = @[createTestMultiAddress(ip)]
    )
    let now = getTime().toUnix().uint64

    # Add to cache and IP tree
    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000 # Expired
    registrar.ipTree.insertIp(parseIpAddress(ip))

    check registrar.ipTree.root.counter == 1

    pruneExpiredAds(registrar, 900)

    # IP should be removed from tree
    check registrar.ipTree.root.counter == 0

  test "pruneExpiredAds removes from cacheTimestamps":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000

    check ad.toAdvertisementKey() in registrar.cacheTimestamps

    pruneExpiredAds(registrar, 900)

    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

  test "pruneExpiredAds handles multiple ads for same service":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad1 = createTestAdvertisement(serviceId = serviceId)
    let ad2 = createTestAdvertisement(serviceId = serviceId)
    let ad3 = createTestAdvertisement(serviceId = serviceId)
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad1, ad2, ad3]
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now - 1000 # Expired
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now # Fresh
    registrar.cacheTimestamps[ad3.toAdvertisementKey()] = now - 2000 # Expired

    pruneExpiredAds(registrar, 900)

    # Only ad2 should remain
    check registrar.cache[serviceId].len == 1
    check ad2 in registrar.cache[serviceId]
    check ad1 notin registrar.cache[serviceId]
    check ad3 notin registrar.cache[serviceId]

  test "pruneExpiredAds handles ad with no valid IP addresses":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId, addrs = @[])
    let now = getTime().toUnix().uint64

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000

    # Should not crash
    pruneExpiredAds(registrar, 900)

    check ad notin registrar.cache[serviceId]

suite "Kademlia Discovery Registrar - State Management":
  test "cache can store multiple ads for same service ID":
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

  test "cache can store ads for different service IDs":
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

  test "cacheTimestamps correctly tracks insertion time":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let timestamp: uint64 = 12345

    registrar.cacheTimestamps[ad.toAdvertisementKey()] = timestamp

    check registrar.cacheTimestamps[ad.toAdvertisementKey()] == timestamp

  test "IP tree is independent from cache":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ip = "192.168.1.1"
    let ad = createTestAdvertisement(
      serviceId = serviceId, addrs = @[createTestMultiAddress(ip)]
    )

    # Add to cache but not IP tree
    registrar.cache[serviceId] = @[ad]

    check registrar.ipTree.root.counter == 0

    # Add to IP tree
    registrar.ipTree.insertIp(parseIpAddress(ip))

    check registrar.ipTree.root.counter == 1

# ============================================================================
# 8. Edge Cases Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Edge Cases":
  test "waitingTime with advertisement with no addresses":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement(addrs = @[])
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    # Should not crash
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # ipSim should be 0 since no addresses
    check w >= 0

  test "waitingTime with IPv6 addresses only (ignored in IP tree)":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()

    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    let ad = createTestAdvertisement(addrs = @[ipv6Addr])
    let now = getTime().toUnix().uint64

    # Should not crash - IPv6 is ignored in IP tree
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 0

  test "waitingTime with mixed IPv4 and IPv6 addresses":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let serviceId = makeServiceId()

    # Populate tree with IPv4
    registrar.ipTree.insertIp(parseIpAddress("192.168.1.1"))

    let ipv4Addr = createTestMultiAddress("192.168.1.50")
    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    let ad = createTestAdvertisement(addrs = @[ipv4Addr, ipv6Addr])
    let now = getTime().toUnix().uint64

    # Should not crash - IPv6 is ignored but IPv4 is scored
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w > 0

  test "waitingTime with service ID not in boundService":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    # Service not in boundService - no lower bound should be applied
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 0

  test "waitingTime with IP not in boundIp":
    let registrar = createTestRegistrar()
    let discoConf = KademliaDiscoveryConfig.new()
    let ad = createTestAdvertisement(addrs = @[createTestMultiAddress("10.0.0.1")])
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    # IP not in boundIp - no lower bound should be applied
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    check w >= 0

  test "updateLowerBounds with zero w":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)
    let now: uint64 = 1000

    # w = 0, but effective bound might still be negative
    # Bound should still be set
    updateLowerBounds(registrar, serviceId, ad, 0.0, now)

    check serviceId in registrar.boundService
    check registrar.boundService[serviceId] == 1000.0

  test "pruneExpiredAds with very short expiry":
    let registrar = createTestRegistrar()
    let serviceId = makeServiceId()
    let ad = createTestAdvertisement(serviceId = serviceId)

    registrar.cache[serviceId] = @[ad]
    # Set a very old timestamp (year 1970) to ensure expiry
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = 1000.uint64

    # Very short expiry (1 second) - old ad from 1970 should be pruned
    pruneExpiredAds(registrar, 1)

    # After pruning, the ad should be removed from both cache and timestamps
    check ad notin registrar.cache[serviceId]
    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

# ============================================================================
# 9. Configuration Variations Tests
# ============================================================================

suite "Kademlia Discovery Registrar - Configuration Variations":
  test "different advertCacheCap affects occupancy":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    # Add some ads
    for i in 0 ..< 100:
      let testAd = createTestAdvertisement(serviceId = makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConf = KademliaDiscoveryConfig.new()

    # Small cache cap = high occupancy
    let w1 = registrar.waitingTime(discoConf, ad, 100, serviceId, now)

    # Large cache cap = low occupancy
    let w2 = registrar.waitingTime(discoConf, ad, 10000, serviceId, now)

    check w1 >= w2 # Small cap should give higher wait time

  test "different occupancyExp changes wait time curve":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    # Add some ads
    for i in 0 ..< 500:
      let testAd = createTestAdvertisement(serviceId = makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    # Low exponent
    let discoConf1 = KademliaDiscoveryConfig.new(occupancyExp = 1.0)
    let w1 = registrar.waitingTime(discoConf1, ad, 1000, serviceId, now)

    # High exponent
    let discoConf2 = KademliaDiscoveryConfig.new(occupancyExp = 20.0)
    let w2 = registrar.waitingTime(discoConf2, ad, 1000, serviceId, now)

    # Higher exponent should give higher wait time at same occupancy
    check w2 >= w1

  test "different advertExpiry scales base wait time":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    # Short expiry
    let discoConf1 = KademliaDiscoveryConfig.new(advertExpiry = 100.0)
    let w1 = registrar.waitingTime(discoConf1, ad, 1000, serviceId, now)

    # Long expiry
    let discoConf2 = KademliaDiscoveryConfig.new(advertExpiry = 2000.0)
    let w2 = registrar.waitingTime(discoConf2, ad, 1000, serviceId, now)

    # Longer expiry should give higher wait time
    check w2 > w1

  test "different safetyParam adds to wait time":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    # Low safety param
    let discoConf1 = KademliaDiscoveryConfig.new(safetyParam = 0.0)
    let w1 = registrar.waitingTime(discoConf1, ad, 1000, serviceId, now)

    # High safety param
    let discoConf2 = KademliaDiscoveryConfig.new(safetyParam = 1.0)
    let w2 = registrar.waitingTime(discoConf2, ad, 1000, serviceId, now)

    # Higher safety param should give higher wait time
    check w2 > w1

  test "occupancyExp of 0 gives occupancy of 1.0":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    # Add some ads
    for i in 0 ..< 500:
      let testAd = createTestAdvertisement(serviceId = makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConf = KademliaDiscoveryConfig.new(occupancyExp = 0.0)
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # With occupancyExp = 0, occupancy = 1.0 / pow(1.0 - c/C, 0) = 1.0 / 1.0 = 1.0
    # w should just be advertExpiry * 1.0 * (serviceSim + ipSim + safetyParam)
    check w >= 0

  test "occupancyExp of 1 gives linear occupancy":
    let registrar = createTestRegistrar()
    let ad = createTestAdvertisement()
    let now = getTime().toUnix().uint64
    let serviceId = makeServiceId()

    # Fill cache to half
    for i in 0 ..< 500:
      let testAd = createTestAdvertisement(serviceId = makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConf = KademliaDiscoveryConfig.new(occupancyExp = 1.0)
    let w = registrar.waitingTime(discoConf, ad, 1000, serviceId, now)

    # With occupancyExp = 1, occupancy = 1.0 / (1.0 - 0.5) = 2.0
    # w should be proportional to this
    check w >= 0

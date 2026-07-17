# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, math, results, tables
import
  ../../../libp2p/[
    crypto/crypto,
    extended_peer_record,
    multiaddress,
    peerid,
    protocols/service_discovery/registrar,
    protocols/service_discovery/types,
    routing_record,
    signed_envelope,
    utils/iptree,
  ]
import ../../../libp2p/protocols/kademlia/protobuf as kadprotobuf
import ../../tools/[crypto, unittest]
import ./utils

func initMoment(secs: int64): Moment =
  Moment.init(secs, Second)

func inFloatSecs(d: Duration): float64 =
  d.secs.float64

proc makeAdvertisementWithServices(
    services: seq[ServiceInfo],
    privateKey: PrivateKey = PrivateKey.random(rng()).get(),
    addrs: seq[MultiAddress] = @[],
    seqNo: uint64 = Moment.now().epochSeconds.uint64,
): Advertisement =
  let peerId = PeerId.init(privateKey).get()
  var addressInfos: seq[AddressInfo]
  for address in addrs:
    addressInfos.add(AddressInfo(address: address))

  let extRecord = ExtendedPeerRecord(
    peerId: peerId, seqNo: seqNo, addresses: addressInfos, services: services
  )
  SignedExtendedPeerRecord.init(privateKey, extRecord).get()

suite "Service Discovery Registrar - Waiting Time Calculation":
  test "waitingTime returns low value for empty cache with no IP similarity":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let now = Moment.now()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # With empty cache: c = 0, occupancy = 1.0, c_s = 0, ipSim = 0
    # w = advertExpiry * 1.0 * (0 + 0 + safetyParam)
    let expected =
      round(discoConfig.advertExpiry.seconds.float64 * discoConfig.safetyParam)

    check abs(w.inFloatSecs - expected) < 0.001

  test "waitingTime increases with cache occupancy":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad1 = makeAdvertisement($serviceId1)
    let ad2 = makeAdvertisement($serviceId2)
    let now = Moment.now()

    registrar.cache[serviceId1] = @[ad1]
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now
    let w1 = registrar.waitingTime(discoConfig, ad1, 100, serviceId1, now)

    registrar.cache[serviceId2] = @[ad2]
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now
    let w2 = registrar.waitingTime(discoConfig, ad2, 100, serviceId2, now)

    check w1 < w2

  test "waitingTime increases with service similarity":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let serviceId3 = makeServiceId(3)
    let serviceId4 = makeServiceId(4)
    let ad1 = makeAdvertisement($serviceId1)
    let ad2 = makeAdvertisement($serviceId2)
    let ad3 = makeAdvertisement($serviceId3)
    let ad4 = makeAdvertisement($serviceId4)
    let ad5 = makeAdvertisement($serviceId4)
    let ad6 = makeAdvertisement($serviceId4)
    let now = Moment.now()

    registrar.cache[serviceId1] = @[ad1]
    registrar.cache[serviceId2] = @[ad2]
    registrar.cache[serviceId3] = @[ad3]
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad3.toAdvertisementKey()] = now

    let w1 = registrar.waitingTime(discoConfig, ad1, 100, serviceId1, now)

    registrar.cache.clear()
    registrar.cacheTimestamps.clear()

    registrar.cache[serviceId4] = @[ad4, ad5, ad6]
    registrar.cacheTimestamps[ad4.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad5.toAdvertisementKey()] = now
    registrar.cacheTimestamps[ad6.toAdvertisementKey()] = now
    let w2 = registrar.waitingTime(discoConfig, ad4, 100, serviceId4, now)

    check w1 < w2

  test "waitingTime returns 0.0 IP similarity for IPs not in tree":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("192.168.1.1")])
    let now = Moment.now()

    # Tree is empty so IP score is 0
    check registrar.ipTree.ipScore(
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    ) == 0.0

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w == ZeroDuration

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
    let now = Moment.now()
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w > ZeroDuration

  test "waitingTime at cache capacity returns high occupancy":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement()
    let serviceId = makeServiceId()

    for i in 0 ..< 1000:
      let testAd = makeAdvertisement($i)
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = Moment.now()

    let now = Moment.now()
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # At capacity, occupancy = 100.0
    # Allow 1 ns tolerance: float->ns truncation can lose a sub-nanosecond fraction
    let expectedSecs =
      round(discoConfig.advertExpiry.seconds.float64 * 100.0 * discoConfig.safetyParam)
    check w.inFloatSecs >= expectedSecs - 1e-9

  test "waitingTime formula includes safety parameter":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new(safetyParam = 0.5)
    let ad = makeAdvertisement()
    let now = Moment.now()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # Empty cache, no IP sim: w = advertExpiry * 1.0 * safetyParam
    let expected =
      ceil(discoConfig.advertExpiry.seconds.float64 * discoConfig.safetyParam)
    check abs(w.inFloatSecs - expected) < 1.0

  test "waitingTime ipSimCoefficient=0 eliminates IP similarity penalty":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new(ipSimCoefficient = 0.0)
    let serviceId = makeServiceId()

    # Six nodes on the same /24 already registered
    for i in 1 .. 6:
      let ip =
        IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, uint8(i)])
      registrar.ipTree.insertIp(ip)
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("192.168.1.7")])
    registrar.cache[serviceId] = newSeq[Advertisement](6)
    let now = Moment.now()
    for i in 0 ..< 6:
      registrar.cacheTimestamps[(peerId: ad.data.peerId, seqNo: uint64(i))] = now

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # With ipSimCoefficient=0, ipSim is excluded; w is driven only by serviceSim (6/1000)
    # w = 900 * ~1.0 * (0.006 + 0 + 1e-7) ≈ 5.4s  →  well under 10s
    check w < 10.seconds

  test "waitingTime ipSimCoefficient=1 (default) preserves IP similarity penalty":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new(ipSimCoefficient = 1.0)
    let serviceId = makeServiceId()

    for i in 1 .. 6:
      let ip =
        IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, uint8(i)])
      registrar.ipTree.insertIp(ip)
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("192.168.1.7")])

    let now = Moment.now()
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # ipSim ≈ 0.97 for same /24; w should be in the hundreds of seconds
    check w > 500.seconds

suite "Service Discovery Registrar - advertExpiry cap":
  test "registration caps the offered tWaitFor at advertExpiry":
    let advertExpiry = 100.secs
    let conf = ServiceDiscoveryConfig.new(
      advertExpiry = advertExpiry, safetyParam = 1.0, advertCacheCap = 10
    )
    let disco = setupServiceDiscoveryNode(discoConfig = conf)
    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let advertiserKey = PrivateKey.random(rng()).get()
    let advertiserId = PeerId.init(advertiserKey).get()
    let adBytes = makeAdvertisement(serviceName, advertiserKey).encode().get()

    # Saturate the cache: occupancy pins at 100.0, so w = 100*100*1.0 = 10000s.
    for i in 0 ..< 10:
      disco.registrar.cacheTimestamps[(peerId: randomPeerId(), seqNo: uint64(i))] =
        Moment.now()

    let inMsg = kadprotobuf.Message(
      msgType: kadprotobuf.MessageType.register,
      key: serviceId,
      register: Opt.some(
        kadprotobuf.RegisterMessage(
          advertisement: adBytes,
          status: Opt.none(kadprotobuf.RegistrationStatus),
          ticket: Opt.none(Ticket),
        )
      ),
    )
    let reply = disco.registration(advertiserId, inMsg).register.get()

    check reply.status.get() == kadprotobuf.RegistrationStatus.Wait
    check reply.ticket.get().tWaitFor.get() == advertExpiry

  test "sustained overload keeps offering advertExpiry-length waits across retries":
    let advertExpiry = 100.secs
    let registrationWindow = 10.secs
    let conf = ServiceDiscoveryConfig.new(
      advertExpiry = advertExpiry,
      safetyParam = 1.0,
      advertCacheCap = 10,
      registrationWindow = registrationWindow,
    )
    let disco = setupServiceDiscoveryNode(discoConfig = conf)
    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let advertiserKey = PrivateKey.random(rng()).get()
    let advertiserId = PeerId.init(advertiserKey).get()
    let adBytes = makeAdvertisement(serviceName, advertiserKey).encode().get()

    for i in 0 ..< 10:
      disco.registrar.cacheTimestamps[(peerId: randomPeerId(), seqNo: uint64(i))] =
        Moment.now()

    let firstAttemptTime =
      Moment.init((Moment.now() - advertExpiry).epochSeconds, Second)
    var retryTicket = Ticket(
      advertisement: adBytes,
      tInit: firstAttemptTime,
      tMod: firstAttemptTime,
      tWaitFor: advertExpiry,
      signature: Opt.none(seq[byte]),
    )
    check retryTicket.sign(disco.switch.peerInfo.privateKey).isOk()

    let inMsg = kadprotobuf.Message(
      msgType: kadprotobuf.MessageType.register,
      key: serviceId,
      register: Opt.some(
        kadprotobuf.RegisterMessage(
          advertisement: adBytes,
          status: Opt.none(kadprotobuf.RegistrationStatus),
          ticket: Opt.some(retryTicket),
        )
      ),
    )
    let reply = disco.registration(advertiserId, inMsg).register.get()

    check reply.status.get() == kadprotobuf.RegistrationStatus.Wait
    check reply.ticket.get().tWaitFor.get() == advertExpiry

suite "Service Discovery Registrar - Lower Bound Enforcement":
  test "waitingTime enforces service lower bound when exists":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = initMoment(1000)

    # bound = 1500, timestamp = 1000 → effective = 1500 - 0 = 1500
    registrar.boundService[serviceId] = initMoment(1500)
    registrar.timestampService[serviceId] = initMoment(1000)

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= 500.secs

  test "waitingTime enforces IP lower bound when exists":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ip = "192.168.1.50"
    let ad = makeAdvertisement(addrs = @[makeMultiAddress(ip)])
    let now = initMoment(1000)
    let serviceId = makeServiceId()

    registrar.boundIp[ip] = initMoment(1500)
    registrar.timestampIp[ip] = initMoment(1000)

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= 500.secs

  test "waitingTime IP lower bound is per IP address":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let now = initMoment(1000)
    let serviceId = makeServiceId()

    registrar.boundIp[ip1] = initMoment(1500)
    registrar.timestampIp[ip1] = initMoment(1000)

    let ad2 = makeAdvertisement(addrs = @[makeMultiAddress(ip2)])
    let w2 = registrar.waitingTime(discoConfig, ad2, 1000, serviceId, now)

    let ad1 = makeAdvertisement(addrs = @[makeMultiAddress(ip1)])
    let w1 = registrar.waitingTime(discoConfig, ad1, 1000, serviceId, now)

    check w1 > w2

  test "waitingTime uses most restrictive lower bound":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new(advertExpiry = 2500.secs)
    let serviceId = makeServiceId()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let now = initMoment(1000)

    registrar.boundService[serviceId] = initMoment(2000)
    registrar.timestampService[serviceId] = initMoment(1000)

    registrar.boundIp[ip1] = initMoment(3000)
    registrar.timestampIp[ip1] = initMoment(1000)

    registrar.boundIp[ip2] = initMoment(1500)
    registrar.timestampIp[ip2] = initMoment(1000)

    let ad = makeAdvertisement(
      $serviceId, addrs = @[makeMultiAddress(ip1), makeMultiAddress(ip2)]
    )

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= 2000.secs

suite "Service Discovery Registrar - Lower Bound Updates":
  test "updateLowerBounds stores service bound as w":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = initMoment(1000)
    let w = 500.secs

    updateLowerBounds(registrar, serviceId, ad, w, now)

    check serviceId in registrar.boundService
    check registrar.boundService[serviceId] == now + w
    check registrar.timestampService[serviceId] == now

  test "updateLowerBounds updates service bound when w exceeds effective bound":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = initMoment(1000)

    registrar.boundService[serviceId] = initMoment(1500)
    registrar.timestampService[serviceId] = initMoment(500)
    # effective = 1500 - (1000 - 500) = 1000; new w = 1200 > 1000 → update

    updateLowerBounds(registrar, serviceId, ad, 1200.secs, now)

    check registrar.boundService[serviceId] == initMoment(2200)
    check registrar.timestampService[serviceId] == initMoment(1000)

  test "updateLowerBounds does not decrease service bound":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = initMoment(1000)

    registrar.boundService[serviceId] = initMoment(2500)
    registrar.timestampService[serviceId] = initMoment(500)
    # effective = 2500 - 500 = 2000; new w = 1000 < 2000 → no update
    let oldBound = registrar.boundService[serviceId]

    updateLowerBounds(registrar, serviceId, ad, 1000.secs, now)

    check registrar.boundService[serviceId] == oldBound

  test "updateLowerBounds updates IP bound for each address":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ip1 = "192.168.1.1"
    let ip2 = "10.0.0.1"
    let ad = makeAdvertisement(
      $serviceId, addrs = @[makeMultiAddress(ip1), makeMultiAddress(ip2)]
    )
    let now = initMoment(1000)
    let w = 500.secs

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

    updateLowerBounds(registrar, serviceId, ad, 500.secs, initMoment(1000))
    check registrar.boundService[serviceId] == initMoment(1500)

    updateLowerBounds(registrar, serviceId, ad, 800.secs, initMoment(1500))
    check registrar.boundService[serviceId] == initMoment(2300)

    updateLowerBounds(registrar, serviceId, ad, 1200.secs, initMoment(2000))
    check registrar.boundService[serviceId] == initMoment(3200)

  test "updateLowerBounds with empty addresses does not crash":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId, addrs = @[])
    let now = initMoment(1000)

    updateLowerBounds(registrar, serviceId, ad, 500.secs, now)

    check registrar.boundService[serviceId] == initMoment(1500)

suite "Service Discovery Registrar - Cache Pruning":
  test "pruneExpiredAds does nothing on empty registrar":
    let registrar = Registrar.new()

    pruneExpiredAds(registrar, 900.secs)

    check registrar.cache.len == 0
    check registrar.cacheTimestamps.len == 0

  test "pruneExpiredAds keeps ad within expiry time":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = Moment.now()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now

    pruneExpiredAds(registrar, 900.secs)

    check ad in registrar.cache[serviceId]
    check ad.toAdvertisementKey() in registrar.cacheTimestamps

  test "pruneExpiredAds removes ad past expiry time":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = Moment.now()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000.secs

    pruneExpiredAds(registrar, 900.secs)

    check ad notin registrar.cache.getOrDefault(serviceId)
    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

  test "pruneExpiredAds removes ad from IP tree":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ip = IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    let ad = makeAdvertisement($serviceId, addrs = @[makeMultiAddress("192.168.1.1")])
    let now = Moment.now()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000.secs
    registrar.ipTree.insertIp(ip)

    check registrar.ipTree.root.counter == 1

    pruneExpiredAds(registrar, 900.secs)

    check registrar.ipTree.root.counter == 0

  test "pruneExpiredAds removes from cacheTimestamps":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = Moment.now()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000.secs

    check ad.toAdvertisementKey() in registrar.cacheTimestamps

    pruneExpiredAds(registrar, 900.secs)

    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

  test "pruneExpiredAds handles multiple ads for same service":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad1 = makeAdvertisement($serviceId)
    let ad2 = makeAdvertisement($serviceId)
    let ad3 = makeAdvertisement($serviceId)
    let now = Moment.now()

    registrar.cache[serviceId] = @[ad1, ad2, ad3]
    registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now - 1000.secs # expired
    registrar.cacheTimestamps[ad2.toAdvertisementKey()] = now # fresh
    registrar.cacheTimestamps[ad3.toAdvertisementKey()] = now - 2000.secs # expired

    pruneExpiredAds(registrar, 900.secs)

    check registrar.cache[serviceId].len == 1
    check ad2 in registrar.cache[serviceId]
    check ad1 notin registrar.cache[serviceId]
    check ad3 notin registrar.cache[serviceId]

  test "pruneExpiredAds handles ad with no valid IP addresses":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId, addrs = @[])
    let now = Moment.now()

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000.secs

    pruneExpiredAds(registrar, 900.secs)

    check ad notin registrar.cache.getOrDefault(serviceId)

  test "pruneExpiredAds removes same expired ad from all services":
    let registrar = Registrar.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let now = Moment.now()

    registrar.cache[serviceId1] = @[ad]
    registrar.cache[serviceId2] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000.secs
    # Each service's copy is a separate ad_cache admission
    registrar.ipTree.insertAd(ad)
    registrar.ipTree.insertAd(ad)

    pruneExpiredAds(registrar, 900.secs)

    check:
      registrar.cache.len == 0
      ad.toAdvertisementKey() notin registrar.cacheTimestamps
      registrar.ipTree.root.counter == 0

    # Second prune must be a no-op
    pruneExpiredAds(registrar, 900.secs)
    check registrar.cache.len == 0

  test "pruneExpiredAds removes orphan ad with no timestamp":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)

    registrar.cache[serviceId] = @[ad]
    # Deliberately no cacheTimestamps entry

    pruneExpiredAds(registrar, 900.secs)

    check:
      ad notin registrar.cache.getOrDefault(serviceId)
      registrar.cache.len == 0

  test "pruneExpiredAds progresses past mixed fresh, orphan, and expired ads":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let fresh = makeAdvertisement($serviceId)
    let orphan = makeAdvertisement($serviceId)
    let expired = makeAdvertisement($serviceId)
    let now = Moment.now()

    registrar.cache[serviceId] = @[fresh, orphan, expired]
    registrar.cacheTimestamps[fresh.toAdvertisementKey()] = now
    # orphan has no timestamp
    registrar.cacheTimestamps[expired.toAdvertisementKey()] = now - 1000.secs

    pruneExpiredAds(registrar, 900.secs)

    check:
      registrar.cache[serviceId].len == 1
      fresh in registrar.cache[serviceId]
      orphan notin registrar.cache[serviceId]
      expired notin registrar.cache[serviceId]
      fresh.toAdvertisementKey() in registrar.cacheTimestamps
      expired.toAdvertisementKey() notin registrar.cacheTimestamps

  test "pruneExpiredAds removes multi-service ad from IP tree once per service":
    let registrar = Registrar.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("192.168.1.1")])
    let now = Moment.now()

    registrar.cache[serviceId1] = @[ad]
    registrar.cache[serviceId2] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now - 1000.secs
    # Each service's copy is a separate ad_cache admission
    registrar.ipTree.insertAd(ad)
    registrar.ipTree.insertAd(ad)
    check registrar.ipTree.root.counter == 2

    pruneExpiredAds(registrar, 900.secs)

    check:
      registrar.cache.len == 0
      registrar.ipTree.root.counter == 0

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
    let timestamp = initMoment(12345)

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
    let now = Moment.now()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= ZeroDuration

  test "waitingTime with IPv6 addresses only, tree empty":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    let ad = makeAdvertisement(addrs = @[ipv6Addr])
    let now = Moment.now()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= ZeroDuration

  test "waitingTime with IPv6 addresses contributes IP similarity":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()

    registrar.ipTree.insertIp(
      IpAddress(
        family: IpAddressFamily.IPv6,
        address_v6: [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
      )
    )

    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    let ad = makeAdvertisement(addrs = @[ipv6Addr])
    let now = Moment.now()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w > ZeroDuration

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
    let now = Moment.now()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w > ZeroDuration

  test "waitingTime with service ID not in boundService":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement()
    let now = Moment.now()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= ZeroDuration

  test "waitingTime with IP not in boundIp":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let now = Moment.now()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= ZeroDuration

  test "updateLowerBounds with zero w":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = initMoment(1000)

    updateLowerBounds(registrar, serviceId, ad, ZeroDuration, now)

    check serviceId in registrar.boundService
    check registrar.boundService[serviceId] == now

  test "pruneExpiredAds with very old timestamp":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)

    registrar.cache[serviceId] = @[ad]
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = initMoment(0)

    check ad in registrar.cache.getOrDefault(serviceId)
    check ad.toAdvertisementKey() in registrar.cacheTimestamps

    # expire ads that are older than 1s
    # our ad is very old (moment zero)
    pruneExpiredAds(registrar, 1.secs)

    check ad notin registrar.cache.getOrDefault(serviceId)
    check ad.toAdvertisementKey() notin registrar.cacheTimestamps

suite "Service Discovery Registrar - Configuration Variations":
  test "different advertCacheCap affects occupancy":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = Moment.now()
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
    let now = Moment.now()
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
    let now = Moment.now()
    let serviceId = makeServiceId()

    let discoConfig1 =
      ServiceDiscoveryConfig.new(safetyParam = 1.0, advertExpiry = 100.secs)
    let w1 = registrar.waitingTime(discoConfig1, ad, 1000, serviceId, now)

    let discoConfig2 =
      ServiceDiscoveryConfig.new(safetyParam = 1.0, advertExpiry = 10000.secs)
    let w2 = registrar.waitingTime(discoConfig2, ad, 1000, serviceId, now)

    check w2 > w1

  test "different safetyParam adds to wait time":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = Moment.now()
    let serviceId = makeServiceId()

    let discoConfig1 = ServiceDiscoveryConfig.new(safetyParam = 0.0)
    let w1 = registrar.waitingTime(discoConfig1, ad, 1000, serviceId, now)

    let discoConfig2 = ServiceDiscoveryConfig.new(safetyParam = 1.0)
    let w2 = registrar.waitingTime(discoConfig2, ad, 1000, serviceId, now)

    check w2 > w1

  test "occupancyExp of 0 gives occupancy of 1.0":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = Moment.now()
    let serviceId = makeServiceId()

    for i in 0 ..< 500:
      let testAd = makeAdvertisement($makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConfig = ServiceDiscoveryConfig.new(occupancyExp = 0.0)
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # pow(x, 0) = 1.0 regardless of x, so occupancy = 1.0 / 1.0 = 1.0
    check w >= ZeroDuration

  test "occupancyExp of 1 gives linear occupancy":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = Moment.now()
    let serviceId = makeServiceId()

    for i in 0 ..< 500:
      let testAd = makeAdvertisement($makeServiceId(i.byte))
      registrar.cacheTimestamps[testAd.toAdvertisementKey()] = now

    let discoConfig = ServiceDiscoveryConfig.new(occupancyExp = 1.0)
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    # occupancyExp=1: occupancy = 1/(1-0.5) = 2.0
    check w >= ZeroDuration

suite "Service Discovery Registrar - Register Message Validation":
  test "isValidAdvertisement rejects empty advertisement":
    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: @[],
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    check isValidAdvertisement(regMsg, makeServiceId()).isErr()

  test "isValidAdvertisement rejects malformed advertisement bytes":
    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: @[1'u8, 2, 3, 4],
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    check isValidAdvertisement(regMsg, makeServiceId()).isErr()

  test "isValidAdvertisement accepts decodable advertisement":
    let serviceStr = $1
    let serviceId = hashServiceId(serviceStr)
    let ad = makeAdvertisement(serviceStr, addrs = @[makeMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    let decoded = isValidAdvertisement(regMsg, serviceId)

    check decoded.isOk()
    check decoded.get().data.peerId == ad.data.peerId
    check decoded.get().data.seqNo == ad.data.seqNo

  test "isValidAdvertisement rejects advertisement for different service":
    let serviceId = "service".hashServiceId()
    let ad = makeAdvertisement("other-service")
    let adBuf = ad.encode().get()
    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    check isValidAdvertisement(regMsg, serviceId).isErr()

  test "isValidAdvertisement rejects advertisement with no services":
    let serviceId = "service".hashServiceId()
    let ad = makeAdvertisementWithServices(@[])
    let adBuf = ad.encode().get()
    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    check isValidAdvertisement(regMsg, serviceId).isErr()

  test "isValidAdvertisement accepts multi-service advertisement":
    let services = @[
      makeServiceInfo("service-a"),
      makeServiceInfo("service-b"),
      makeServiceInfo("service-c"),
    ]
    let serviceId = services[0].id.hashServiceId()
    let ad = makeAdvertisementWithServices(services)
    let adBuf = ad.encode().get()
    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.none(Ticket),
    )

    let decoded = isValidAdvertisement(regMsg, serviceId)

    check:
      decoded.isOk()
      decoded.get().data.peerId == ad.data.peerId
      decoded.get().data.services.len == 3

suite "Service Discovery Registrar - Retry Ticket Processing":
  test "subtracts accumulated wait for retry":
    let disco = setupServiceDiscoveryNode()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let adBuf = ad.encode().get()

    # Set tMod = now, tWaitFor = 0 → windowStart = now (within window)
    # totalWaitSoFar = now - (now - 150) = 150 ± 1
    let now = Moment.now()
    var ticket = Ticket(
      advertisement: adBuf,
      tInit: now - 150.secs,
      tMod: now,
      tWaitFor: 0.secs,
      signature: Opt.none(seq[byte]),
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let regMsg = kadprotobuf.RegisterMessage(
      advertisement: adBuf,
      status: Opt.none(kadprotobuf.RegistrationStatus),
      ticket: Opt.some(ticket),
    )
    var tWait = 300.secs

    disco.updateWaitAfterRetry(regMsg.ticket, now, tWait)

    # totalWaitSoFar = 150 ± 1; tRemaining = 150 ± 1
    check abs(tWait.secs - 150) <= 1

suite "Service Discovery Registrar - registration rejects invalid tickets":
  # These tests exercise the full registration() path (not just the helper).
  # Cryptographically invalid tickets must produce Rejected and must never
  # influence tInit or other time values in any response.

  test "registration with mismatched ticket advertisement yields Rejected":
    let disco = setupServiceDiscoveryNode()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let adBuf = ad.encode().get()
    let otherAd = makeAdvertisement("other-service")
    let otherBuf = otherAd.encode().get()

    var ticket = Ticket(
      advertisement: otherBuf,
      tInit: Moment.init(1_000, Second),
      tMod: Moment.now(),
      tWaitFor: 0.secs,
      signature: Opt.none(seq[byte]),
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let inMsg = kadprotobuf.Message(
      msgType: kadprotobuf.MessageType.register,
      key: serviceId,
      register: Opt.some(
        kadprotobuf.RegisterMessage(
          advertisement: adBuf,
          status: Opt.none(kadprotobuf.RegistrationStatus),
          ticket: Opt.some(ticket),
        )
      ),
    )

    let reply = disco.registration(ad.data.peerId, inMsg).register.get()
    check reply.status.get() == kadprotobuf.RegistrationStatus.Rejected
    check reply.ticket.isNone()
    check disco.countAdsInCache(serviceId) == 0

  test "registration with invalid-signature ticket yields Rejected":
    let disco = setupServiceDiscoveryNode()
    let otherDisco = setupServiceDiscoveryNode()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let adBuf = ad.encode().get()

    var ticket = Ticket(
      advertisement: adBuf,
      tInit: Moment.init(1_000, Second),
      tMod: Moment.now(),
      tWaitFor: 0.secs,
      signature: Opt.none(seq[byte]),
    )
    check ticket.sign(otherDisco.switch.peerInfo.privateKey).isOk()

    let inMsg = kadprotobuf.Message(
      msgType: kadprotobuf.MessageType.register,
      key: serviceId,
      register: Opt.some(
        kadprotobuf.RegisterMessage(
          advertisement: adBuf,
          status: Opt.none(kadprotobuf.RegistrationStatus),
          ticket: Opt.some(ticket),
        )
      ),
    )

    let reply = disco.registration(ad.data.peerId, inMsg).register.get()
    check reply.status.get() == kadprotobuf.RegistrationStatus.Rejected
    check reply.ticket.isNone()
    check disco.countAdsInCache(serviceId) == 0

suite "Service Discovery Registrar - acceptAdvertisement seqNo handling":
  test "new peer ad is added to cache":
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = Moment.now()

    disco.acceptAdvertisement(now, serviceId, ad)

    check disco.registrar.cache.getOrDefault(serviceId).len == 1
    check disco.registrar.cache[serviceId][0].data.peerId == ad.data.peerId

  test "same peer same seqNo is treated as duplicate and not added again":
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = Moment.now()

    disco.acceptAdvertisement(now, serviceId, ad)
    disco.acceptAdvertisement(now, serviceId, ad)

    check disco.registrar.cache[serviceId].len == 1

  test "same peer higher seqNo replaces existing ad":
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId = makeServiceId()
    let privateKey = PrivateKey.random(rng()).get()
    let peerId = PeerId.init(privateKey).get()
    let now = Moment.now()

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

    disco.acceptAdvertisement(now, serviceId, oldAd)
    check disco.registrar.cache[serviceId][0].data.seqNo == 1

    disco.acceptAdvertisement(now, serviceId, newAd)

    check disco.registrar.cache[serviceId].len == 1
    check disco.registrar.cache[serviceId][0].data.seqNo == 2

  test "same peer lower seqNo is silently dropped":
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId = makeServiceId()
    let privateKey = PrivateKey.random(rng()).get()
    let peerId = PeerId.init(privateKey).get()
    let now = Moment.now()

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

    disco.acceptAdvertisement(now, serviceId, newerAd)
    disco.acceptAdvertisement(now, serviceId, olderAd)

    check disco.registrar.cache[serviceId].len == 1
    check disco.registrar.cache[serviceId][0].data.seqNo == 10

  test "different peers each store their own ad":
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId = makeServiceId()
    let ad1 = makeAdvertisement($serviceId)
    let ad2 = makeAdvertisement($serviceId)
    let now = Moment.now()

    disco.acceptAdvertisement(now, serviceId, ad1)
    disco.acceptAdvertisement(now, serviceId, ad2)

    check disco.registrar.cache[serviceId].len == 2

  test "seqNo replacement updates IP tree correctly":
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId = makeServiceId()
    let privateKey = PrivateKey.random(rng()).get()
    let peerId = PeerId.init(privateKey).get()
    let now = Moment.now()

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

    disco.acceptAdvertisement(now, serviceId, oldAd)
    let counterAfterFirst = disco.registrar.ipTree.root.counter
    check counterAfterFirst > 0

    disco.acceptAdvertisement(now, serviceId, newAd)

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
    registrar.boundService[serviceId] = initMoment(100)
    registrar.timestampService[serviceId] = initMoment(0)

    let now = Moment.now()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= ZeroDuration

  test "waitingTime returns non-negative with stale high IP lower bound":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ip = "10.0.0.1"

    registrar.boundIp[ip] = initMoment(50)
    registrar.timestampIp[ip] = initMoment(0)

    let ad = makeAdvertisement(addrs = @[makeMultiAddress(ip)])
    let now = Moment.now()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= ZeroDuration

suite "Service Discovery Registrar - concurrent same-peer registration":
  test "repeated acceptAdvertisement calls for same ad are idempotent":
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = Moment.now()

    disco.acceptAdvertisement(now, serviceId, ad)
    disco.acceptAdvertisement(now, serviceId, ad)

    check disco.registrar.cache[serviceId].len == 1

suite "Service Discovery Registrar - updateExistingAd":
  test "same seqNo refreshes timestamp and returns false":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    var ads = @[ad]
    let oldTime = initMoment(1000)
    let newTime = initMoment(2000)

    registrar.cacheTimestamps[ad.toAdvertisementKey()] = oldTime
    registrar.ipTree.insertAd(ad)
    let counterBefore = registrar.ipTree.root.counter

    let changed = registrar.updateExistingAd(ads, 0, ad, newTime)

    check not changed
    check registrar.cacheTimestamps[ad.toAdvertisementKey()] == newTime
    check registrar.ipTree.root.counter == counterBefore

  test "higher seqNo replaces ad, updates timestamps and IP tree, returns true":
    let registrar = Registrar.new()
    let privateKey = PrivateKey.random(rng()).get()
    let oldAd = makeAdvertisement(privateKey = privateKey, seqNo = 1)
    let newAd = makeAdvertisement(privateKey = privateKey, seqNo = 2)
    var ads = @[oldAd]

    registrar.cacheTimestamps[oldAd.toAdvertisementKey()] = initMoment(1000)
    registrar.ipTree.insertAd(oldAd)

    let changed = registrar.updateExistingAd(ads, 0, newAd, initMoment(2000))

    check changed
    check ads.len == 1
    check ads[0].data.seqNo == 2
    check oldAd.toAdvertisementKey() notin registrar.cacheTimestamps
    check newAd.toAdvertisementKey() in registrar.cacheTimestamps
    check registrar.cacheTimestamps[newAd.toAdvertisementKey()] == initMoment(2000)

  test "higher seqNo with address swap removes old IP and inserts new one":
    let registrar = Registrar.new()
    let privateKey = PrivateKey.random(rng()).get()
    let oldAd = makeAdvertisement(
      privateKey = privateKey, seqNo = 1, addrs = @[makeMultiAddress("10.0.0.1")]
    )
    let newAd = makeAdvertisement(
      privateKey = privateKey, seqNo = 2, addrs = @[makeMultiAddress("192.168.1.1")]
    )
    var ads = @[oldAd]

    registrar.ipTree.insertAd(oldAd)
    registrar.cacheTimestamps[oldAd.toAdvertisementKey()] = initMoment(1000)
    let counterBefore = registrar.ipTree.root.counter

    discard registrar.updateExistingAd(ads, 0, newAd, initMoment(2000))

    # IP tree entry count is unchanged: one removed, one added
    check registrar.ipTree.root.counter == counterBefore

  test "lower seqNo leaves cache and timestamps unchanged, returns false":
    let registrar = Registrar.new()
    let privateKey = PrivateKey.random(rng()).get()
    let currentAd = makeAdvertisement(privateKey = privateKey, seqNo = 10)
    let staleAd = makeAdvertisement(privateKey = privateKey, seqNo = 5)
    var ads = @[currentAd]

    registrar.cacheTimestamps[currentAd.toAdvertisementKey()] = initMoment(1000)

    let changed = registrar.updateExistingAd(ads, 0, staleAd, initMoment(2000))

    check not changed
    check ads[0].data.seqNo == 10
    check currentAd.toAdvertisementKey() in registrar.cacheTimestamps
    check staleAd.toAdvertisementKey() notin registrar.cacheTimestamps

  test "higher seqNo replaces stale copies in every other service that cached it":
    let registrar = Registrar.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let privateKey = PrivateKey.random(rng()).get()
    let oldAd = makeAdvertisement(
      privateKey = privateKey, seqNo = 1, addrs = @[makeMultiAddress("10.0.0.1")]
    )
    let newAd = makeAdvertisement(
      privateKey = privateKey, seqNo = 2, addrs = @[makeMultiAddress("192.168.1.1")]
    )

    registrar.cache[serviceId1] = @[oldAd]
    registrar.cache[serviceId2] = @[oldAd]
    registrar.cacheTimestamps[oldAd.toAdvertisementKey()] = initMoment(1000)
    # Each service's copy is a separate ad_cache admission
    registrar.ipTree.insertAd(oldAd)
    registrar.ipTree.insertAd(oldAd)
    check registrar.ipTree.root.counter == 2

    var ads1 = registrar.cache[serviceId1]
    let changed = registrar.updateExistingAd(ads1, 0, newAd, initMoment(2000))
    registrar.cache[serviceId1] = ads1

    check changed
    check registrar.cache[serviceId1].len == 1
    check registrar.cache[serviceId1][0].data.seqNo == 2
    # serviceId2 was never passed into updateExistingAd directly.
    check registrar.cache[serviceId2].len == 1
    check registrar.cache[serviceId2][0].data.seqNo == 2
    check oldAd.toAdvertisementKey() notin registrar.cacheTimestamps
    check newAd.toAdvertisementKey() in registrar.cacheTimestamps
    check registrar.ipTree.root.counter == 2

suite "Service Discovery Registrar - insertNewAd":
  test "inserts ad into cache, IP tree, and timestamps, returns true":
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId = makeServiceId()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    var ads: seq[Advertisement] = @[]
    let now = initMoment(1000)

    let changed = disco.insertNewAd(serviceId, ads, ad, now)

    check changed
    check ads.len == 1
    check ads[0].data.peerId == ad.data.peerId
    check ad.toAdvertisementKey() in disco.registrar.cacheTimestamps
    check disco.registrar.cacheTimestamps[ad.toAdvertisementKey()] == now
    check disco.registrar.ipTree.root.counter > 0

  test "same ad accepted for three services counts the IP tree once per service":
    # ad_cache associates each advertisement to its service_id : the
    # same physical ad admitted for 3 services is 3 separate admissions,
    # each of which adds the IP once - not one shared contribution.
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let serviceId3 = makeServiceId(3)
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let now = initMoment(1000)

    var ads1: seq[Advertisement] = @[]
    var ads2: seq[Advertisement] = @[]
    var ads3: seq[Advertisement] = @[]
    discard disco.insertNewAd(serviceId1, ads1, ad, now)
    discard disco.insertNewAd(serviceId2, ads2, ad, now)
    discard disco.insertNewAd(serviceId3, ads3, ad, now)
    disco.registrar.cache[serviceId1] = ads1
    disco.registrar.cache[serviceId2] = ads2
    disco.registrar.cache[serviceId3] = ads3

    check disco.registrar.ipTree.root.counter == 3

  test "inserts ad without eviction when cache is under capacity":
    let disco = setupServiceDiscoveryNode(
      discoConfig = ServiceDiscoveryConfig.new(fReturn = 3, advertExpiry = 900.secs)
    )
    let serviceId = makeServiceId()
    let existingAd = makeAdvertisement($makeServiceId(99))
    disco.registrar.cacheTimestamps[existingAd.toAdvertisementKey()] = initMoment(1000)

    let newAd = makeAdvertisement()
    var ads: seq[Advertisement] = @[]

    discard disco.insertNewAd(serviceId, ads, newAd, initMoment(2000))

    # Existing ad must still be present (no eviction)
    check existingAd.toAdvertisementKey() in disco.registrar.cacheTimestamps
    check ads.len == 1

  test "evicts oldest entry and inserts new ad when cache is at capacity":
    # Use a small cap so i.byte never overflows (byte wraps at 256)
    let cap = 5
    let config = ServiceDiscoveryConfig.new(
      kRegister = 3, bucketsCount = 16, advertCacheCap = cap.uint64
    )
    let disco = setupServiceDiscoveryNode(discoConfig = config)
    # Use a service id outside the filled range so the working list starts empty
    let serviceId = makeServiceId(100)
    let now = initMoment(5000)

    # Fill cache exactly to capacity; the first entry gets the oldest timestamp
    var oldestAd: Advertisement
    for i in 0 ..< cap:
      let sid = makeServiceId(i.byte)
      let a = makeAdvertisement($sid)
      let ts =
        if i == 0:
          initMoment(100)
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

  test "evictOldestAd removes shared ad from all services":
    # Oldest key is registered under two services; eviction must clear both
    # lists (not leave an orphan without a timestamp).
    let cap = 2
    let config = ServiceDiscoveryConfig.new(
      kRegister = 3, bucketsCount = 16, advertCacheCap = cap.uint64
    )
    let disco = setupServiceDiscoveryNode(discoConfig = config)
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let serviceId3 = makeServiceId(3)
    let now = initMoment(5000)

    let oldestAd = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let otherAd = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.2")])

    disco.registrar.cache[serviceId1] = @[oldestAd]
    disco.registrar.cache[serviceId2] = @[oldestAd]
    disco.registrar.cache[serviceId3] = @[otherAd]
    disco.registrar.cacheTimestamps[oldestAd.toAdvertisementKey()] = initMoment(100)
    disco.registrar.cacheTimestamps[otherAd.toAdvertisementKey()] = now
    disco.registrar.ipTree.insertAd(oldestAd)
    disco.registrar.ipTree.insertAd(otherAd)

    # At capacity (2 unique keys); insert into a fresh service so the working
    # list only receives the new ad after oldestAd is evicted everywhere.
    let newServiceId = makeServiceId(4)
    let newAd = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.3")])
    var ads: seq[Advertisement] = @[]
    discard disco.insertNewAd(newServiceId, ads, newAd, now)

    check:
      oldestAd.toAdvertisementKey() notin disco.registrar.cacheTimestamps
      serviceId1 notin disco.registrar.cache
      serviceId2 notin disco.registrar.cache
      otherAd in disco.registrar.cache.getOrDefault(serviceId3)
      newAd in ads
      ads.len == 1

suite "Service Discovery Registrar - registration response":
  test "wait response records the wait time and does not cache the ad":
    let config = ServiceDiscoveryConfig.new(safetyParam = 1.0)
    let disco = setupServiceDiscoveryNode(discoConfig = config)
    let serviceId1 = makeServiceId(1)
    let serviceIdName = "service"
    let serviceId2 = serviceIdName.hashServiceId()
    let ad1 = makeAdvertisement($serviceId1)
    let ad2 = makeAdvertisement(serviceIdName)
    let adBytes = ad2.encode().get()
    let advertiserId = ad2.data.peerId
    let now = Moment.now()

    disco.registrar.cache[serviceId1] = @[ad1]
    disco.registrar.cacheTimestamps[ad1.toAdvertisementKey()] = now

    let inMsg = kadprotobuf.Message(
      msgType: kadprotobuf.MessageType.register,
      key: serviceId2,
      register: Opt.some(
        kadprotobuf.RegisterMessage(
          advertisement: adBytes,
          status: Opt.none(kadprotobuf.RegistrationStatus),
          ticket: Opt.none(Ticket),
        )
      ),
    )

    let reply = disco.registration(advertiserId, inMsg).register.get()

    check:
      reply.status.get() == kadprotobuf.RegistrationStatus.Wait
      reply.ticket.isSome()
      disco.countAdsInCache(serviceId2) == 0
      serviceId2 in disco.registrar.boundService
      serviceId2 in disco.registrar.timestampService

    let ticket = reply.ticket.get()
    let registrarPubKey = disco.switch.peerInfo.privateKey.getPublicKey().get()
    check:
      ticket.advertisement == adBytes
      ticket.tWaitFor.isSome
      ticket.tWaitFor.get() > ZeroDuration
      ticket.verify(registrarPubKey)

  test "registration quantizes now to whole-second granularity":
    # `now` is read once in registration() and truncated to whole seconds, so
    # every time value it emits — the ticket's tInit/tMod and the recorded
    # service timestamp — must land exactly on a second boundary. Using the
    # raw Moment.now() (sub-second nanoseconds) would break these checks.
    let config = ServiceDiscoveryConfig.new(safetyParam = 1.0) # forces a Wait
    let disco = setupServiceDiscoveryNode(discoConfig = config)
    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let ad = makeAdvertisement(serviceName)
    let adBytes = ad.encode().get()
    let advertiserId = ad.data.peerId

    let inMsg = kadprotobuf.Message(
      msgType: kadprotobuf.MessageType.register,
      key: serviceId,
      register: Opt.some(
        kadprotobuf.RegisterMessage(
          advertisement: adBytes,
          status: Opt.none(kadprotobuf.RegistrationStatus),
          ticket: Opt.none(Ticket),
        )
      ),
    )

    let reply = disco.registration(advertiserId, inMsg).register.get()

    check reply.status.get() == kadprotobuf.RegistrationStatus.Wait
    check reply.ticket.isSome()

    # Reconstructing a Moment from its own epochSeconds is a fixed point only
    # when the moment already has no sub-second part.
    let ticket = reply.ticket.get()
    let tInit = ticket.tInit.get()
    let tMod = ticket.tMod.get()
    check tInit == Moment.init(tInit.epochSeconds, Second)
    check tMod == Moment.init(tMod.epochSeconds, Second)

    # The recorded service timestamp mirrors the same truncated `now`.
    check serviceId in disco.registrar.timestampService
    let ts = disco.registrar.timestampService[serviceId]
    check ts == Moment.init(ts.epochSeconds, Second)

  test "retrying with a valid ticket inside the window caches the ad":
    let conf = ServiceDiscoveryConfig.new(registrationWindow = 10.secs)
    let disco = setupServiceDiscoveryNode(discoConfig = conf)
    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let advertiserKey = PrivateKey.random(rng()).get()
    let advertiserId = PeerId.init(advertiserKey).get()
    let adBytes = makeAdvertisement(serviceName, advertiserKey).encode().get()

    # Sign a ticket whose retry window is already open
    let pastNow = Moment.now() - 5.secs
    var ticket = Ticket(
      advertisement: adBytes,
      tInit: pastNow,
      tMod: pastNow,
      tWaitFor: 1.secs,
      signature: Opt.none(seq[byte]),
    )
    check ticket.sign(disco.switch.peerInfo.privateKey).isOk()

    let inMsg = kadprotobuf.Message(
      msgType: kadprotobuf.MessageType.register,
      key: serviceId,
      register: Opt.some(
        kadprotobuf.RegisterMessage(
          advertisement: adBytes,
          status: Opt.none(kadprotobuf.RegistrationStatus),
          ticket: Opt.some(ticket),
        )
      ),
    )

    let reply = disco.registration(advertiserId, inMsg).register.get()

    check:
      reply.status.get() == kadprotobuf.RegistrationStatus.Confirmed
      disco.countAdsInCache(serviceId) == 1
      disco.getAdsInCache(serviceId)[0].data.peerId == advertiserId

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, math, results, tables, net
import
  ../../../libp2p/[
    crypto/crypto,
    extended_peer_record,
    multiaddress,
    peerid,
    protocols/service_discovery/advertisement_cache,
    protocols/service_discovery/registrar,
    protocols/service_discovery/types,
    routing_record,
    signed_envelope,
  ]
import ../../../libp2p/protocols/kademlia/protobuf as kadprotobuf
import ../../tools/[crypto, unittest]
import ./utils

const HighCap = uint64.high

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

proc seedOccupancy(ads: AdvertisementCache, n: int, now: Moment = Moment.now()) =
  ## Fill the cache with `n` unique ads under distinct services (no serviceSim
  ## on a later subject serviceId).
  for i in 0 ..< n:
    let sid = makeServiceId(byte(i mod 250 + 1))
    let ad = makeAdvertisement($sid)
    discard ads.put(sid, ad, now, HighCap)

suite "Service Discovery Registrar - Waiting Time Calculation":
  test "waitingTime returns low value for empty cache with no IP similarity":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let now = Moment.now()
    let serviceId = makeServiceId()

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

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

    registrar.seedAd(serviceId1, ad1, now)
    let w1 = registrar.waitingTime(discoConfig, ad1, 100, serviceId1, now)

    registrar.seedAd(serviceId2, ad2, now)
    let w2 = registrar.waitingTime(discoConfig, ad2, 100, serviceId2, now)

    check w1 < w2

  test "waitingTime increases with service similarity":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId1 = makeServiceId(1)
    let serviceId4 = makeServiceId(4)
    let ad1 = makeAdvertisement($serviceId1)
    let ad4 = makeAdvertisement($serviceId4)
    let ad5 = makeAdvertisement($serviceId4)
    let ad6 = makeAdvertisement($serviceId4)
    let now = Moment.now()

    # Three ads across three services → low serviceSim for serviceId1
    registrar.seedAd(serviceId1, ad1, now)
    registrar.seedAd(makeServiceId(2), makeAdvertisement($makeServiceId(2)), now)
    registrar.seedAd(makeServiceId(3), makeAdvertisement($makeServiceId(3)), now)
    let w1 = registrar.waitingTime(discoConfig, ad1, 100, serviceId1, now)

    registrar.ads.clear()

    # Three ads under one service → higher serviceSim
    registrar.seedAd(serviceId4, ad4, now)
    registrar.seedAd(serviceId4, ad5, now)
    registrar.seedAd(serviceId4, ad6, now)
    let w2 = registrar.waitingTime(discoConfig, ad4, 100, serviceId4, now)

    check w1 < w2

  test "waitingTime returns 0.0 IP similarity for IPs not in tree":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("192.168.1.1")])
    let now = Moment.now()

    check registrar.ads.ipScore(
      IpAddress(family: IpAddressFamily.IPv4, address_v4: [192'u8, 168, 1, 1])
    ) == 0.0

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w == ZeroDuration

  test "waitingTime uses maximum IP score across multiple addresses":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let now = Moment.now()

    # Seed three nearby IPs under a filler service so the subject serviceSim is 0
    let filler = makeServiceId(99)
    for i in 10 .. 30:
      if i mod 10 == 0:
        let ip = "192.168.1." & $i
        registrar.seedAd(
          filler, makeAdvertisement(addrs = @[makeMultiAddress(ip)]), now
        )

    let ad = makeAdvertisement(
      addrs = @[
        makeMultiAddress("10.0.0.1"), # Different subnet – low score
        makeMultiAddress("192.168.1.50"), # Same subnet – high score
      ]
    )
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w > ZeroDuration

  test "waitingTime at cache capacity returns high occupancy":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let ad = makeAdvertisement()
    let serviceId = makeServiceId()
    let now = Moment.now()

    registrar.ads.seedOccupancy(1000, now)

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

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

    let expected =
      ceil(discoConfig.advertExpiry.seconds.float64 * discoConfig.safetyParam)
    check abs(w.inFloatSecs - expected) < 1.0

  test "waitingTime ipSimCoefficient=0 eliminates IP similarity penalty":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new(ipSimCoefficient = 0.0)
    let serviceId = makeServiceId()
    let now = Moment.now()
    let filler = makeServiceId(99)

    for i in 1 .. 6:
      let ip = "192.168.1." & $i
      registrar.seedAd(filler, makeAdvertisement(addrs = @[makeMultiAddress(ip)]), now)
    # serviceSim for subject service is 0; occupancy is small
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("192.168.1.7")])

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w < 10.seconds

  test "waitingTime ipSimCoefficient=1 (default) preserves IP similarity penalty":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new(ipSimCoefficient = 1.0)
    let serviceId = makeServiceId()
    let now = Moment.now()
    let filler = makeServiceId(99)

    for i in 1 .. 6:
      let ip = "192.168.1." & $i
      registrar.seedAd(filler, makeAdvertisement(addrs = @[makeMultiAddress(ip)]), now)
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("192.168.1.7")])

    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

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

    disco.registrar.ads.seedOccupancy(10)

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

    disco.registrar.ads.seedOccupancy(10)

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

    check registrar.ads.len == 0
    check registrar.ads.serviceCount == 0

  test "pruneExpiredAds keeps ad within expiry time":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = Moment.now()

    registrar.seedAd(serviceId, ad, now)

    pruneExpiredAds(registrar, 900.secs)

    check ad in registrar.ads.adsForService(serviceId)
    check ad.toAdvertisementKey() in registrar.ads

  test "pruneExpiredAds removes ad past expiry time":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = Moment.now()

    registrar.seedAd(serviceId, ad, now - 1000.secs)

    pruneExpiredAds(registrar, 900.secs)

    check ad notin registrar.ads.adsForService(serviceId)
    check ad.toAdvertisementKey() notin registrar.ads

  test "pruneExpiredAds removes ad from IP tree":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId, addrs = @[makeMultiAddress("192.168.1.1")])

    registrar.seedAd(serviceId, ad, Moment.now() - 1000.secs)

    check registrar.ads.ipTotal == 1

    pruneExpiredAds(registrar, 900.secs)

    check registrar.ads.ipTotal == 0

  test "pruneExpiredAds removes from primary table":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)

    registrar.seedAd(serviceId, ad, Moment.now() - 1000.secs)

    check ad.toAdvertisementKey() in registrar.ads

    pruneExpiredAds(registrar, 900.secs)

    check ad.toAdvertisementKey() notin registrar.ads

  test "pruneExpiredAds handles multiple ads for same service":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad1 = makeAdvertisement($serviceId)
    let ad2 = makeAdvertisement($serviceId)
    let ad3 = makeAdvertisement($serviceId)
    let now = Moment.now()

    registrar.seedAd(serviceId, ad1, now - 1000.secs)
    registrar.seedAd(serviceId, ad2, now)
    registrar.seedAd(serviceId, ad3, now - 2000.secs)

    pruneExpiredAds(registrar, 900.secs)

    let remaining = registrar.ads.adsForService(serviceId)
    check remaining.len == 1
    check ad2 in remaining
    check ad1 notin remaining
    check ad3 notin remaining

  test "pruneExpiredAds handles ad with no valid IP addresses":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId, addrs = @[])

    registrar.seedAd(serviceId, ad, Moment.now() - 1000.secs)

    pruneExpiredAds(registrar, 900.secs)

    check ad notin registrar.ads.adsForService(serviceId)

  test "pruneExpiredAds removes same expired ad from all services":
    let registrar = Registrar.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let expired = Moment.now() - 1000.secs

    registrar.seedAd(serviceId1, ad, expired)
    registrar.seedAd(serviceId2, ad, expired)
    check registrar.ads.ipTotal == 2

    pruneExpiredAds(registrar, 900.secs)

    check:
      registrar.ads.serviceCount == 0
      ad.toAdvertisementKey() notin registrar.ads
      registrar.ads.ipTotal == 0

    pruneExpiredAds(registrar, 900.secs)
    check registrar.ads.len == 0

  test "pruneExpiredAds progresses past mixed fresh and expired ads":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let fresh = makeAdvertisement($serviceId)
    let expired = makeAdvertisement($serviceId)
    let now = Moment.now()

    registrar.seedAd(serviceId, fresh, now)
    registrar.seedAd(serviceId, expired, now - 1000.secs)

    pruneExpiredAds(registrar, 900.secs)

    check:
      registrar.ads.adsForService(serviceId).len == 1
      fresh in registrar.ads.adsForService(serviceId)
      expired notin registrar.ads.adsForService(serviceId)
      fresh.toAdvertisementKey() in registrar.ads
      expired.toAdvertisementKey() notin registrar.ads

  test "pruneExpiredAds removes multi-service ad from IP tree once per service":
    let registrar = Registrar.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("192.168.1.1")])
    let expired = Moment.now() - 1000.secs

    registrar.seedAd(serviceId1, ad, expired)
    registrar.seedAd(serviceId2, ad, expired)
    check registrar.ads.ipTotal == 2

    pruneExpiredAds(registrar, 900.secs)

    check:
      registrar.ads.serviceCount == 0
      registrar.ads.ipTotal == 0

suite "Service Discovery Registrar - State Management":
  test "cache can store multiple ads for same service ID":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad1 = makeAdvertisement($serviceId)
    let ad2 = makeAdvertisement($serviceId)
    let ad3 = makeAdvertisement($serviceId)

    registrar.seedAds(serviceId, @[ad1, ad2, ad3])

    check registrar.ads.serviceAdCount(serviceId) == 3
    check ad1 in registrar.ads.adsForService(serviceId)
    check ad2 in registrar.ads.adsForService(serviceId)
    check ad3 in registrar.ads.adsForService(serviceId)

  test "cache can store ads for different service IDs":
    let registrar = Registrar.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let ad1 = makeAdvertisement($serviceId1)
    let ad2 = makeAdvertisement($serviceId2)

    registrar.seedAd(serviceId1, ad1)
    registrar.seedAd(serviceId2, ad2)

    check registrar.ads.serviceCount == 2
    check registrar.ads.containsService(serviceId1)
    check registrar.ads.containsService(serviceId2)

  test "timestamps correctly track insertion time":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement()
    let timestamp = initMoment(12345)

    registrar.seedAd(serviceId, ad, timestamp)

    check registrar.ads.timestamp(ad.toAdvertisementKey()).get() == timestamp

  test "put couples ad storage and IP tree":
    let registrar = Registrar.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId, addrs = @[makeMultiAddress("192.168.1.1")])

    check registrar.ads.ipTotal == 0
    registrar.seedAd(serviceId, ad)
    check registrar.ads.ipTotal == 1
    check ad in registrar.ads.adsForService(serviceId)

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
    let now = Moment.now()
    let filler = makeServiceId(99)

    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    registrar.seedAd(filler, makeAdvertisement(addrs = @[ipv6Addr]), now)

    let ad = makeAdvertisement(addrs = @[ipv6Addr])
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w > ZeroDuration

  test "waitingTime with mixed IPv4 and IPv6 addresses":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let now = Moment.now()
    let filler = makeServiceId(99)

    registrar.seedAd(
      filler, makeAdvertisement(addrs = @[makeMultiAddress("192.168.1.1")]), now
    )

    let ipv4Addr = makeMultiAddress("192.168.1.50")
    let ipv6Addr = MultiAddress.init("/ip6/::1/tcp/9000").get()
    let ad = makeAdvertisement(addrs = @[ipv4Addr, ipv6Addr])

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

    registrar.seedAd(serviceId, ad, initMoment(0))

    check ad in registrar.ads.adsForService(serviceId)
    check ad.toAdvertisementKey() in registrar.ads

    pruneExpiredAds(registrar, 1.secs)

    check ad notin registrar.ads.adsForService(serviceId)
    check ad.toAdvertisementKey() notin registrar.ads

suite "Service Discovery Registrar - Configuration Variations":
  test "different advertCacheCap affects occupancy":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = Moment.now()
    let serviceId = makeServiceId()

    registrar.ads.seedOccupancy(100, now)

    let discoConfig = ServiceDiscoveryConfig.new()
    let w1 = registrar.waitingTime(discoConfig, ad, 100, serviceId, now)
    let w2 = registrar.waitingTime(discoConfig, ad, 10000, serviceId, now)

    check w1 >= w2

  test "different occupancyExp changes wait time curve":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = Moment.now()
    let serviceId = makeServiceId()

    registrar.ads.seedOccupancy(500, now)

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

    registrar.ads.seedOccupancy(500, now)

    let discoConfig = ServiceDiscoveryConfig.new(occupancyExp = 0.0)
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

    check w >= ZeroDuration

  test "occupancyExp of 1 gives linear occupancy":
    let registrar = Registrar.new()
    let ad = makeAdvertisement()
    let now = Moment.now()
    let serviceId = makeServiceId()

    registrar.ads.seedOccupancy(500, now)

    let discoConfig = ServiceDiscoveryConfig.new(occupancyExp = 1.0)
    let w = registrar.waitingTime(discoConfig, ad, 1000, serviceId, now)

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

    check abs(tWait.secs - 150) <= 1

suite "Service Discovery Registrar - registration rejects invalid tickets":
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

    check disco.registrar.ads.serviceAdCount(serviceId) == 1
    check disco.registrar.ads.adsForService(serviceId)[0].data.peerId == ad.data.peerId

  test "same peer same seqNo is treated as duplicate and not added again":
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)
    let now = Moment.now()

    disco.acceptAdvertisement(now, serviceId, ad)
    disco.acceptAdvertisement(now, serviceId, ad)

    check disco.registrar.ads.serviceAdCount(serviceId) == 1

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
    check disco.registrar.ads.adsForService(serviceId)[0].data.seqNo == 1

    disco.acceptAdvertisement(now, serviceId, newAd)

    check disco.registrar.ads.serviceAdCount(serviceId) == 1
    check disco.registrar.ads.adsForService(serviceId)[0].data.seqNo == 2

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

    check disco.registrar.ads.serviceAdCount(serviceId) == 1
    check disco.registrar.ads.adsForService(serviceId)[0].data.seqNo == 10

  test "different peers each store their own ad":
    let disco =
      setupServiceDiscoveryNode(discoConfig = ServiceDiscoveryConfig.new(fReturn = 3))
    let serviceId = makeServiceId()
    let ad1 = makeAdvertisement($serviceId)
    let ad2 = makeAdvertisement($serviceId)
    let now = Moment.now()

    disco.acceptAdvertisement(now, serviceId, ad1)
    disco.acceptAdvertisement(now, serviceId, ad2)

    check disco.registrar.ads.serviceAdCount(serviceId) == 2

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
    let counterAfterFirst = disco.registrar.ads.ipTotal
    check counterAfterFirst > 0

    disco.acceptAdvertisement(now, serviceId, newAd)

    check disco.registrar.ads.serviceAdCount(serviceId) == 1
    check disco.registrar.ads.adsForService(serviceId)[0].data.seqNo == 2
    check disco.registrar.ads.ipTotal == counterAfterFirst

suite "Service Discovery Registrar - waitingTime never negative":
  test "waitingTime returns non-negative with stale high service lower bound":
    let registrar = Registrar.new()
    let discoConfig = ServiceDiscoveryConfig.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement($serviceId)

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

    check disco.registrar.ads.serviceAdCount(serviceId) == 1

suite "Service Discovery Registrar - AdvertisementCache put":
  test "same seqNo refreshes timestamp and returns AdRefreshed":
    let ads = AdvertisementCache.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement()
    let oldTime = initMoment(1000)
    let newTime = initMoment(2000)

    check ads.put(serviceId, ad, oldTime, HighCap) == AdInserted
    let counterBefore = ads.ipTotal

    check ads.put(serviceId, ad, newTime, HighCap) == AdRefreshed
    check ads.timestamp(ad.toAdvertisementKey()).get() == newTime
    check ads.ipTotal == counterBefore
    check ads.serviceAdCount(serviceId) == 1

  test "higher seqNo replaces ad, updates timestamps and IP tree, returns AdReplaced":
    let ads = AdvertisementCache.new()
    let serviceId = makeServiceId()
    let privateKey = PrivateKey.random(rng()).get()
    let oldAd = makeAdvertisement(privateKey = privateKey, seqNo = 1)
    let newAd = makeAdvertisement(privateKey = privateKey, seqNo = 2)

    check ads.put(serviceId, oldAd, initMoment(1000), HighCap) == AdInserted
    check ads.put(serviceId, newAd, initMoment(2000), HighCap) == AdReplaced

    check ads.serviceAdCount(serviceId) == 1
    check ads.adsForService(serviceId)[0].data.seqNo == 2
    check oldAd.toAdvertisementKey() notin ads
    check newAd.toAdvertisementKey() in ads
    check ads.timestamp(newAd.toAdvertisementKey()).get() == initMoment(2000)

  test "higher seqNo with address swap keeps IP multi-set size stable":
    let ads = AdvertisementCache.new()
    let serviceId = makeServiceId()
    let privateKey = PrivateKey.random(rng()).get()
    let oldAd = makeAdvertisement(
      privateKey = privateKey, seqNo = 1, addrs = @[makeMultiAddress("10.0.0.1")]
    )
    let newAd = makeAdvertisement(
      privateKey = privateKey, seqNo = 2, addrs = @[makeMultiAddress("192.168.1.1")]
    )

    discard ads.put(serviceId, oldAd, initMoment(1000), HighCap)
    let counterBefore = ads.ipTotal

    discard ads.put(serviceId, newAd, initMoment(2000), HighCap)

    check ads.ipTotal == counterBefore

  test "lower seqNo leaves cache unchanged, returns AdIgnored":
    let ads = AdvertisementCache.new()
    let serviceId = makeServiceId()
    let privateKey = PrivateKey.random(rng()).get()
    let currentAd = makeAdvertisement(privateKey = privateKey, seqNo = 10)
    let staleAd = makeAdvertisement(privateKey = privateKey, seqNo = 5)

    discard ads.put(serviceId, currentAd, initMoment(1000), HighCap)
    check ads.put(serviceId, staleAd, initMoment(2000), HighCap) == AdIgnored

    check ads.adsForService(serviceId)[0].data.seqNo == 10
    check currentAd.toAdvertisementKey() in ads
    check staleAd.toAdvertisementKey() notin ads

  test "higher seqNo replaces stale copies in every other service that cached it":
    let ads = AdvertisementCache.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let privateKey = PrivateKey.random(rng()).get()
    let oldAd = makeAdvertisement(
      privateKey = privateKey, seqNo = 1, addrs = @[makeMultiAddress("10.0.0.1")]
    )
    let newAd = makeAdvertisement(
      privateKey = privateKey, seqNo = 2, addrs = @[makeMultiAddress("192.168.1.1")]
    )

    discard ads.put(serviceId1, oldAd, initMoment(1000), HighCap)
    discard ads.put(serviceId2, oldAd, initMoment(1000), HighCap)
    check ads.ipTotal == 2

    check ads.put(serviceId1, newAd, initMoment(2000), HighCap) == AdReplaced

    check ads.adsForService(serviceId1)[0].data.seqNo == 2
    check ads.adsForService(serviceId2)[0].data.seqNo == 2
    check oldAd.toAdvertisementKey() notin ads
    check newAd.toAdvertisementKey() in ads
    check ads.ipTotal == 2

  test "inserts ad into cache, IP tree, and timestamps":
    let ads = AdvertisementCache.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let now = initMoment(1000)

    check ads.put(serviceId, ad, now, HighCap) == AdInserted
    check ads.serviceAdCount(serviceId) == 1
    check ads.adsForService(serviceId)[0].data.peerId == ad.data.peerId
    check ad.toAdvertisementKey() in ads
    check ads.timestamp(ad.toAdvertisementKey()).get() == now
    check ads.ipTotal > 0

  test "same ad accepted for three services counts the IP tree once per service":
    let ads = AdvertisementCache.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let serviceId3 = makeServiceId(3)
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let now = initMoment(1000)

    discard ads.put(serviceId1, ad, now, HighCap)
    discard ads.put(serviceId2, ad, now, HighCap)
    discard ads.put(serviceId3, ad, now, HighCap)

    check ads.len == 1
    check ads.ipTotal == 3
    check ads.serviceCount == 3

  test "inserts ad without eviction when cache is under capacity":
    let ads = AdvertisementCache.new()
    let serviceId = makeServiceId()
    let existingAd = makeAdvertisement($makeServiceId(99))
    discard ads.put(makeServiceId(99), existingAd, initMoment(1000), capacity = 10)

    let newAd = makeAdvertisement()
    discard ads.put(serviceId, newAd, initMoment(2000), capacity = 10)

    check existingAd.toAdvertisementKey() in ads
    check newAd.toAdvertisementKey() in ads

  test "evicts oldest entry when cache is at capacity":
    let cap = 5'u64
    let ads = AdvertisementCache.new()
    let now = initMoment(5000)

    var oldestAd: Advertisement
    for i in 0 ..< int(cap):
      let sid = makeServiceId(byte(i + 1))
      let a = makeAdvertisement($sid)
      let ts =
        if i == 0:
          initMoment(100)
        else:
          now
      discard ads.put(sid, a, ts, cap)
      if i == 0:
        oldestAd = a

    let newServiceId = makeServiceId(100)
    let newAd = makeAdvertisement()
    check ads.put(newServiceId, newAd, now, cap) == AdInserted

    check oldestAd.toAdvertisementKey() notin ads
    check newAd.toAdvertisementKey() in ads
    check ads.len == int(cap)

  test "eviction removes shared ad from all services":
    let cap = 2'u64
    let ads = AdvertisementCache.new()
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let serviceId3 = makeServiceId(3)
    let now = initMoment(5000)

    let oldestAd = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let otherAd = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.2")])

    discard ads.put(serviceId1, oldestAd, initMoment(100), cap)
    discard ads.put(serviceId2, oldestAd, initMoment(100), cap)
    discard ads.put(serviceId3, otherAd, now, cap)
    check ads.len == 2

    let newServiceId = makeServiceId(4)
    let newAd = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.3")])
    discard ads.put(newServiceId, newAd, now, cap)

    check:
      oldestAd.toAdvertisementKey() notin ads
      not ads.containsService(serviceId1)
      not ads.containsService(serviceId2)
      otherAd in ads.adsForService(serviceId3)
      newAd in ads.adsForService(newServiceId)

  test "remove is idempotent":
    let ads = AdvertisementCache.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    discard ads.put(serviceId, ad, Moment.now(), HighCap)

    check ads.remove(ad.toAdvertisementKey())
    check not ads.remove(ad.toAdvertisementKey())
    check ads.len == 0
    check ads.ipTotal == 0

  test "double put same ad is idempotent for structure":
    let ads = AdvertisementCache.new()
    let serviceId = makeServiceId()
    let ad = makeAdvertisement(addrs = @[makeMultiAddress("10.0.0.1")])
    let now = Moment.now()

    discard ads.put(serviceId, ad, now, HighCap)
    discard ads.put(serviceId, ad, now, HighCap)

    check ads.len == 1
    check ads.serviceAdCount(serviceId) == 1
    check ads.ipTotal == 1

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

    disco.registrar.seedAd(serviceId1, ad1, now)

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
    let config = ServiceDiscoveryConfig.new(safetyParam = 1.0)
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

    let ticket = reply.ticket.get()
    let tInit = ticket.tInit.get()
    let tMod = ticket.tMod.get()
    check tInit == Moment.init(tInit.epochSeconds, Second)
    check tMod == Moment.init(tMod.epochSeconds, Second)

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

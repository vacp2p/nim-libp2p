# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, sequtils, tables
import
  ../../../../libp2p/[
    crypto/crypto,
    peerid,
    protocols/kademlia/routing_table,
    protocols/kademlia/types,
    protocols/service_discovery/advertiser,
    protocols/service_discovery/discoverer,
    protocols/service_discovery/registrar,
    protocols/service_discovery/types,
    switch,
  ]
import ../../../../libp2p/protocols/kademlia/protobuf as kad_protobuf
import ../../../tools/[lifecycle, unittest]
import ../utils

# The setup* procs below use the static lookup table exported from ../utils
# (populated offline by the commented generator there). Review of call sites
# shows only the service name "service" is ever passed to setupRegistrarsIn*
# (the other tests use different ad-hoc names but do not call those procs).
# Thus we use the least number of services (1) to minimize static table size.
proc bucketOf(r: ServiceDiscovery, serviceId: ServiceId): int =
  bucketIndex(
    serviceId,
    r.switch.peerInfo.peerId.toKey(),
    Opt.none(XorDHasher),
    maxBuckets = r.discoConfig.bucketsCount,
    selfIdPreHashed = true,
  )

proc setupRegistrarsInDistinctBuckets(
    conf: ServiceDiscoveryConfig, serviceId: ServiceId
): tuple[queriedFirst, queriedSecond: ServiceDiscovery] =
  ## Two registrars in distinct buckets of the routing table rooted at `serviceId`.
  ## Returned in the order `lookup()` would visit them (lower bucket index first).

  let svcName = "service"
  let pk0 = getStaticPrivateKeyForBucket(svcName, 0)
  # Get a key for a higher bucket (we have entries for 1).
  var pk1 = pk0
  for b in 1 ..< conf.bucketsCount:
    if b in precomputedStaticBucketKeys[svcName] and
        precomputedStaticBucketKeys[svcName][b].len > 0:
      pk1 = getStaticPrivateKeyForBucket(svcName, b)
      break
  let n0 = setupServiceDiscoveryNode(discoConfig = conf, privateKey = Opt.some(pk0))
  let n1 = setupServiceDiscoveryNode(discoConfig = conf, privateKey = Opt.some(pk1))
  let bb0 = bucketOf(n0, serviceId)
  let bb1 = bucketOf(n1, serviceId)
  if bb0 < bb1:
    return (n0, n1)
  else:
    return (n1, n0)

proc setupRegistrarsInSameBucket(
    conf: ServiceDiscoveryConfig, serviceId: ServiceId, count: int
): seq[ServiceDiscovery] =
  ## Registrars that land in one service routing table bucket.

  doAssert count > 0, "count must be > 0"
  let svcName = "service"
  # Find a bucket that has enough precomputed keys (will be 0 for "service").
  var chosenB = -1
  for b, lst in precomputedStaticBucketKeys[svcName]:
    if lst.len >= count:
      chosenB = b
      break
  if chosenB >= 0:
    var nodes: seq[ServiceDiscovery]
    for i in 0 ..< count:
      let pk = getStaticPrivateKeyForBucket(svcName, chosenB)
      nodes.add(
        setupServiceDiscoveryNode(discoConfig = conf, privateKey = Opt.some(pk))
      )
    # Optional sanity: all should report the same bucket (the chosen one).
    return nodes
  raiseAssert "static table not populated with enough keys for " & svcName

suite "Service Discovery Component - Lookup Get Ads":
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

    let regResult = await advertiserNode.sendRegister(
      registrarNode.switch.peerInfo.peerId, serviceId, adBytes
    )
    check regResult.isOk()
    check regResult.get().status == kad_protobuf.RegistrationStatus.Confirmed

    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len == 1
    check found.containsPeer(advertiserNode)

  asyncTest "GET_ADS respects F_return limit":
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0, fReturn = 2)
    let registrarNode = setupServiceDiscoveryNode(discoConfig = conf)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)
    startAndDeferStop(@[registrarNode, discovererNode])
    await connect(registrarNode, discovererNode)

    let serviceName = "limited-service"
    let serviceId = serviceName.hashServiceId()

    for _ in 0 ..< 4:
      let ad = makeAdvertisement(serviceName)
      let now = Moment.now()
      registrarNode.acceptAdvertisement(now, serviceId, ad)

    let found = await discovererNode.lookup(serviceId)
    check found.isOk()
    check found.get().len <= 2

  asyncTest "discoverer discards ads with the service not matching the key":
    let registrarNode = setupServiceDiscoveryNode()
    let discovererNode = setupServiceDiscoveryNode()
    startAndDeferStop(@[registrarNode, discovererNode])
    await connect(registrarNode, discovererNode)

    let serviceIdA = "service-A".hashServiceId()
    let adB = makeAdvertisement(serviceId = "service-B")
    # Plant ad for service-B under key for service-A.
    # The registrar will return it, the discoverer must drop it.
    registrarNode.registrar.cache[serviceIdA] = @[adB]

    let found = await discovererNode.lookup(serviceIdA)
    check found.isOk()
    check found.get().len == 0

  asyncTest "lookup stops querying once F_lookup ads are found":
    # fLookup small so one GET_ADS response fits under MaxMsgSize=4096.
    const fLookup = 8
    let conf = ServiceDiscoveryConfig.new(
      safetyParam = 0.0, fLookup = fLookup, fReturn = fLookup
    )
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let registrars = setupRegistrarsInDistinctBuckets(conf, serviceId)

    startAndDeferStop(
      @[discovererNode, registrars.queriedFirst, registrars.queriedSecond]
    )
    await connect(discovererNode, registrars.queriedFirst)
    await connect(discovererNode, registrars.queriedSecond)

    # The first-queried registrar fills the result on its own.
    var firstBucketAds: seq[Advertisement]
    for _ in 0 ..< fLookup:
      firstBucketAds.add(makeAdvertisement(serviceName))
    registrars.queriedFirst.registrar.cache[serviceId] = firstBucketAds

    # The other should never be queried, so should not appear in the result.
    let otherKey = randomKey()
    let otherAd = makeAdvertisement(serviceName, privateKey = otherKey)
    let otherPeerId = PeerId.init(otherKey).get()
    registrars.queriedSecond.registrar.cache[serviceId] = @[otherAd]

    let found = await discovererNode.lookup(serviceId)
    check:
      found.get().len == fLookup
      not found.get().anyIt(it.data.peerId == otherPeerId)

  asyncTest "lookup queries K_lookup registrars per bucket":
    const kLookup = 2
    let conf = ServiceDiscoveryConfig.new(
      safetyParam = 0.0, kLookup = kLookup, fLookup = 30, fReturn = 1
    )
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let registrars = setupRegistrarsInSameBucket(conf, serviceId, kLookup + 2)

    startAndDeferStop(@[discovererNode] & registrars)
    for registrar in registrars:
      await connect(discovererNode, registrar)
      registrar.registrar.cache[serviceId] = @[makeAdvertisement(serviceName)]

    let found = await discovererNode.lookup(serviceId)
    check:
      found.isOk()
      found.get().len == kLookup

  asyncTest "lookup iterates buckets from farthest to closest":
    # fLookup=1, only the first-queried registrar's ad is returned
    let conf = ServiceDiscoveryConfig.new(safetyParam = 0.0, fLookup = 1)
    let discovererNode = setupServiceDiscoveryNode(discoConfig = conf)

    let serviceName = "service"
    let serviceId = serviceName.hashServiceId()
    let registrars = setupRegistrarsInDistinctBuckets(conf, serviceId)

    startAndDeferStop(
      @[discovererNode, registrars.queriedFirst, registrars.queriedSecond]
    )
    await connect(discovererNode, registrars.queriedFirst)
    await connect(discovererNode, registrars.queriedSecond)

    let firstBucketKey = randomKey()
    let firstBucketAd = makeAdvertisement(serviceName, privateKey = firstBucketKey)
    let secondBucketAd = makeAdvertisement(serviceName)
    registrars.queriedFirst.registrar.cache[serviceId] = @[firstBucketAd]
    registrars.queriedSecond.registrar.cache[serviceId] = @[secondBucketAd]

    let found = await discovererNode.lookup(serviceId)
    check:
      found.get().len == 1
      found.get()[0].data.peerId == PeerId.init(firstBucketKey).get()

  asyncTest "discoverer learns closer peers from GET_ADS reply":
    let discovererNode = setupServiceDiscoveryNode()
    let registrarNode = setupServiceDiscoveryNode()
    let otherNode = setupServiceDiscoveryNode()

    startAndDeferStop(@[discovererNode, registrarNode, otherNode])
    await connect(registrarNode, otherNode)
    await connect(registrarNode, discovererNode)

    let
      serviceId = "service".hashServiceId()
      otherKey = otherNode.switch.peerInfo.peerId.toKey()

    check:
      not discovererNode.rtable.hasPeer(otherKey)
      discovererNode.rtManager.getTable(serviceId).isNone()

    let found = await discovererNode.lookup(serviceId)
    check:
      found.get().len == 0

    let serviceTable = discovererNode.rtManager.getTable(serviceId).get()
    check:
      serviceTable.hasPeer(otherKey)
      discovererNode.rtable.hasPeer(otherKey)

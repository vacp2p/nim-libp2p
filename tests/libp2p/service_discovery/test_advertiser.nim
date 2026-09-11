# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, sets, tables
import
  ../../../libp2p/[
    extended_peer_record,
    peeraddrpolicy,
    peerinfo,
    protocols/kademlia,
    protocols/service_discovery,
    protocols/service_discovery/advertiser,
  ]
import ../../tools/[unittest, multiaddress, lifecycle]
import ./utils

proc holdUntil(gate: AsyncEvent) {.async: (raises: [CancelledError]).} =
  ## A republish caught mid-flight: a cancel lands only once `gate` fires.
  await noCancel gate.wait()

proc settleStartupRepublish(disco: ServiceDiscovery) {.async.} =
  if disco.addressRepublish.isNil():
    return
  await disco.addressRepublish

suite "Advertiser - republish on address change":
  teardown:
    checkTrackers()

  asyncTest "a newer address change waits for the pending republish to drain":
    let disco = setupServiceDiscoveryNode(services = @[makeServiceInfo()])
    startAndDeferStop(@[disco])
    await disco.settleStartupRepublish()

    let gate = newAsyncEvent()
    let held = holdUntil(gate)
    disco.addressRepublish = held
    let loopBefore = disco.signedPeerRecordLoop

    disco.switch.peerInfo.notifyObservers()
    let first = disco.addressRepublish
    disco.switch.peerInfo.notifyObservers()
    let second = disco.addressRepublish

    await sleepAsync(20.millis)
    check:
      first != held
      second != first
      not first.finished()
      not second.finished()
      disco.signedPeerRecordLoop == loopBefore

    gate.fire()
    await second
    check:
      held.completed()
      first.finished()
      second.completed()
      disco.signedPeerRecordLoop != loopBefore

  asyncTest "stop drains the pending republish before it clears the advertiser":
    let disco = setupServiceDiscoveryNode(services = @[makeServiceInfo()])
    startAndDeferStop(@[disco])
    await disco.settleStartupRepublish()

    let gate = newAsyncEvent()
    disco.addressRepublish = holdUntil(gate)
    disco.switch.peerInfo.notifyObservers()
    let pending = disco.addressRepublish

    let stopping = disco.stop()
    await sleepAsync(20.millis)
    check:
      not stopping.finished()
      not pending.finished()
      disco.advertiser.providedAdverts.len == 1

    gate.fire()
    await stopping
    check:
      pending.finished()
      disco.addressRepublish.isNil()
      disco.addressObserver.isNil()
      disco.advertiser.providedAdverts.len == 0

    disco.switch.peerInfo.notifyObservers()
    check disco.addressRepublish.isNil()

suite "Advertiser - addProvidedService":
  teardown:
    checkTrackers()

  test "creates routing table entry for the service":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    disco.populateRoutingTable(1)
    check disco.addProvidedService(service).isOk()

    check disco.rtManager.hasService(serviceId)

  test "caches this node's record when the caller supplies no advertisement":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    disco.populateRoutingTable(1)
    check disco.addProvidedService(service).isOk()

    let cached = disco.advertiser.providedAdverts[serviceId].bytes
    let ad = Advertisement.decode(cached).get()
    check:
      ad.data.peerId == disco.switch.peerInfo.peerId
      ad.advertisesService(serviceId)

    disco.switch.peerInfo.addrs = @[makeMultiAddress("10.0.0.2")]
    check disco.record().get().encode() != cached
    check disco.advertiser.providedAdverts[serviceId].bytes == cached

  asyncTest "a moved address rebuilds the cached record":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    check disco.addProvidedService(service).isOk()

    let moved = makeMultiAddress("10.0.0.2")
    disco.switch.peerInfo.addrs = @[moved]
    await disco.republishProvidedAdverts()

    let ad =
      Advertisement.decode(disco.advertiser.providedAdverts[serviceId].bytes).get()
    check:
      ad.data.addresses.len == 1
      ad.data.addresses[0].address == moved

  asyncTest "a moved address keeps a caller-supplied advertisement":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()
    let advert = makeAdvertisement(service.id).encode()

    check disco.addProvidedService(service, Opt.some(advert)).isOk()

    disco.switch.peerInfo.addrs = @[makeMultiAddress("10.0.0.2")]
    await disco.republishProvidedAdverts()

    check disco.advertiser.providedAdverts[serviceId].bytes == advert

  test "with empty routing table: creates table but schedules no actions":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    check disco.addProvidedService(service).isOk()

    check disco.rtManager.hasService(serviceId)
    check disco.advertiser.running.len() == 0

  test "schedules up to kRegister actions per populated bucket":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    disco.populateAdvertisementTable(serviceId)
    check disco.addProvidedService(service).isOk()

    check disco.advertiser.running.len() == disco.discoConfig.kRegister

  test "scheduling caps at kRegister tasks per populated bucket":
    let kRegister = 3
    let conf = ServiceDiscoveryConfig.new(kRegister = kRegister)
    let disco = setupServiceDiscoveryNode(discoConfig = conf)
    disco.populateRoutingTable(100)

    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    check disco.rtManager.addService(
      serviceId, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
      Interest,
    )

    let table = disco.rtManager.getTable(serviceId).get()
    var overpopulatedBuckets = 0
    for bucket in mitems(table.buckets):
      if bucket.peers.len <= kRegister:
        bucket.peers = @[]
      else:
        overpopulatedBuckets.inc
    check overpopulatedBuckets > 0

    check disco.addProvidedService(service).isOk()

    check disco.advertiser.running.len() == overpopulatedBuckets * kRegister

  asyncTest "adding the same service twice fails until it is removed":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    disco.populateRoutingTable(1)
    check disco.addProvidedService(service).isOk()
    let runningAfterFirst = disco.advertiser.running.len()

    check disco.addProvidedService(service).isErr()

    check disco.rtManager.hasService(serviceId)
    check disco.advertiser.running.len() == runningAfterFirst

    await disco.removeProvidedService(service.id)
    check disco.addProvidedService(service).isOk()

  test "a failed record build leaves no half-added service behind":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    var addrs: seq[MultiAddress]
    for _ in 1 .. 200: # enough that the record no longer fits MaxXPRSize
      addrs.add(makeMultiAddress("10.0.0.1"))
    disco.switch.peerInfo.addrs = addrs
    check disco.record().isErr()

    check disco.addProvidedService(service).isErr()
    check not disco.rtManager.hasService(serviceId)

    disco.switch.peerInfo.addrs = @[makeMultiAddress("10.0.0.1")]
    check disco.addProvidedService(service).isOk()

  test "multiple distinct services each get their own routing table":
    let disco = setupServiceDiscoveryNode()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")
    let s3 = makeServiceInfo("svc-3")

    disco.populateRoutingTable(1)
    check disco.addProvidedService(s1).isOk()
    check disco.addProvidedService(s2).isOk()
    check disco.addProvidedService(s3).isOk()

    check disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())
    check disco.rtManager.hasService(s3.id.hashServiceId())
    check disco.advertiser.running.len() == 3

suite "Advertiser - caller-supplied advertisement":
  teardown:
    checkTrackers()

  test "stores a valid advertisement for reuse on rotation":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let advert = makeAdvertisement(service.id).encode()

    disco.populateRoutingTable(1)

    check disco.addProvidedService(service, Opt.some(advert)).isOk()
    check disco.advertiser.providedAdverts[service.id.hashServiceId()].bytes == advert

  test "rejects an advertisement that does not decode":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    check disco.addProvidedService(service, Opt.some(@[1'u8, 2, 3, 4])).isErr()
    check not disco.rtManager.hasService(service.id.hashServiceId())

  test "rejects an advertisement for another service":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo("wanted-service")
    let advert = makeAdvertisement("other-service").encode()

    check disco.addProvidedService(service, Opt.some(advert)).isErr()
    check not disco.rtManager.hasService(service.id.hashServiceId())

  test "rejects an advertisement with oversized service data":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let advert = makeOversizedAdvertisement(service.id).encode()

    check disco.addProvidedService(service, Opt.some(advert)).isErr()
    check not disco.rtManager.hasService(service.id.hashServiceId())

  test "rejects an advertisement padded past MaxXPRSize with unknown fields":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let advert = padAdvertisement(makeAdvertisement(service.id).encode(), MaxXPRSize)

    # the decoder skips the padding, so only the incoming length rejects this
    check advert.len > MaxXPRSize
    check Advertisement.decode(advert).isOk()

    check disco.addProvidedService(service, Opt.some(advert)).isErr()
    check not disco.rtManager.hasService(service.id.hashServiceId())

  asyncTest "a new advertisement needs a stop before a restart":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()
    let first = makeAdvertisement(service.id).encode()
    let second = makeAdvertisement(service.id).encode()
    check first != second # each helper call signs with a fresh key

    disco.populateRoutingTable(1)

    check disco.startAdvertising(service, Opt.some(first)).isOk()
    check disco.startAdvertising(service, Opt.some(second)).isErr()
    check disco.advertiser.providedAdverts[serviceId].bytes == first

    await disco.stopAdvertising(service.id)

    check disco.startAdvertising(service, Opt.some(second)).isOk()
    check disco.advertiser.providedAdverts[serviceId].bytes == second

suite "Advertiser - maintainRegistrations":
  teardown:
    checkTrackers()

  asyncTest "stops scheduling in client mode and resumes on an upgrade":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    disco.populateAdvertisementTable(service.id.hashServiceId())
    check disco.addProvidedService(service).isOk()

    await disco.advertiser.clear()
    await disco.localRegistrationLoop.cancelAndWait()
    check await disco.changeMode(isServer = false)

    await disco.maintainRegistrations()

    check disco.advertiser.running.len() == 0
    check disco.localRegistrationLoop.finished()

    check await disco.changeMode(isServer = true)

    await disco.maintainRegistrations()

    check disco.advertiser.running.len() > 0
    check not disco.localRegistrationLoop.finished()

suite "Advertiser - removeProvidedService":
  teardown:
    checkTrackers()

  asyncTest "removes routing table and clears its pending actions":
    let disco = setupServiceDiscoveryNode()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")
    let sid1 = s1.id.hashServiceId()
    let sid2 = s2.id.hashServiceId()

    disco.populateRoutingTable(1)
    check disco.addProvidedService(s1).isOk()
    check disco.addProvidedService(s2).isOk()

    await disco.removeProvidedService(s1.id)
    disco.unregisterInterest(s1.id) # local registrar has interest too

    check:
      not disco.rtManager.hasService(sid1)
      disco.rtManager.hasService(sid2)
      disco.advertiser.running.len() == 1

  asyncTest "cancels the service bootstrap future once the table is gone":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let sid = service.id.hashServiceId()

    disco.populateRoutingTable(1)
    check disco.addProvidedService(service).isOk()
    discard disco.registerInterest(service.id)
    check disco.rtManager.serviceStatus[sid] == Both

    let bootstrapFut = newFuture[void]("test service bootstrap")
    disco.serviceBootstrapFuts[sid] = bootstrapFut

    await disco.removeProvidedService(service.id)
    check sid in disco.serviceBootstrapFuts # interest keeps the table alive

    disco.unregisterInterest(service.id)
    await sleepAsync(0.millis) # let the pending cancellation run

    check:
      sid notin disco.serviceBootstrapFuts
      bootstrapFut.cancelled()

  asyncTest "removing non-existent service is a no-op":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()

    await disco.removeProvidedService(service.id)
    check not disco.rtManager.hasService(service.id.hashServiceId())

  asyncTest "removing one service leaves others intact":
    let disco = setupServiceDiscoveryNode()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    disco.populateRoutingTable(1)
    check disco.addProvidedService(s1).isOk()
    check disco.addProvidedService(s2).isOk()

    await disco.removeProvidedService(s1.id)
    disco.unregisterInterest(s1.id) # local registrar has interest too

    check not disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())

suite "Advertiser - record creation":
  teardown:
    checkTrackers()

  test "record creation rejects service data larger than MaxServiceDataSize":
    let validData = newSeq[byte](MaxServiceDataSize)
    let discoValid = setupServiceDiscoveryNode(
      services = @[ServiceInfo(id: "service", data: validData)]
    )
    let recordValid = discoValid.record()
    check recordValid.isOk()
    let svc = recordValid.get().data.services[0]
    check:
      svc.isValid()
      svc.data.get().len == MaxServiceDataSize

    let oversizedData = newSeq[byte](MaxServiceDataSize + 1)
    let badSvc = ServiceInfo(id: "service", data: oversizedData)
    let discoBad = setupServiceDiscoveryNode(services = @[badSvc])
    let recordBad = discoBad.record()
    check:
      not badSvc.isValid()
      recordBad.isErr()

  test "record creation rejects encoded XPR larger than MaxXPRSize":
    let discoSmall = setupServiceDiscoveryNode(services = @[makeServiceInfo("service")])
    let recordSmall = discoSmall.record()
    check recordSmall.isOk()
    let smallXpr = recordSmall.get()
    check:
      smallXpr.isValid()
      smallXpr.encode().get().len <= MaxXPRSize

    let discoBig = setupServiceDiscoveryNode(services = @[makeServiceInfo("service")])
    let baseAddr = makeMultiAddress("10.0.0.1")
    var addrs: seq[MultiAddress]
    var foundOversized = false

    for _ in 1 .. 10_000:
      addrs.add(baseAddr)
      discoBig.switch.peerInfo.addrs = addrs
      let rec = discoBig.record()
      if rec.isErr():
        foundOversized = true
        break
      let enc = rec.get().encode()
      if enc.isOk and enc.get().len > MaxXPRSize:
        foundOversized = true
        break

    check foundOversized

    let recordBig = discoBig.record()
    check recordBig.isErr()

  test "record creation filters addresses using kadConfig.addressPolicy":
    let
      publicAddr = makeMultiAddress("1.1.1.1")
      privateAddr = makeMultiAddress("192.168.1.1")
      mixed = @[privateAddr, publicAddr]

    let policyConf = KadDHTConfig.new(addressPolicy = publicRoutableAddressPolicy)
    let disco = setupServiceDiscoveryNode(
      services = @[makeServiceInfo("service")], kadConfig = policyConf
    )
    disco.switch.peerInfo.addrs = mixed

    let rec = disco.record()
    check rec.isOk()
    let xprAddrs = rec.get().data.addresses
    check:
      xprAddrs.len == 1
      xprAddrs[0].address == publicAddr

    # default policy (no filtering) keeps all addresses
    let discoDef = setupServiceDiscoveryNode(services = @[makeServiceInfo("service")])
    discoDef.switch.peerInfo.addrs = mixed
    let recDef = discoDef.record()
    check recDef.isOk()
    check recDef.get().data.addresses.len == 2

  test "record creation drops an undialable address by default":
    let disco = setupServiceDiscoveryNode(services = @[makeServiceInfo("service")])
    let routable = makeMultiAddress("10.0.0.1")
    disco.switch.peerInfo.addrs =
      @[ma("/ip4/0.0.0.0/tcp/60000"), ma("/ip4/127.0.0.1/tcp/0"), routable]

    let rec = disco.record()
    check rec.isOk()
    let xprAddrs = rec.get().data.addresses
    check:
      xprAddrs.len == 1
      xprAddrs[0].address == routable

  test "record creation fails while nothing dialable is announced":
    let disco = setupServiceDiscoveryNode(services = @[makeServiceInfo("service")])

    disco.switch.peerInfo.addrs = @[ma("/ip4/0.0.0.0/tcp/60000")]
    check disco.record().isErr()

    disco.switch.peerInfo.addrs = @[]
    check disco.record().isErr()

  test "record creation keeps an undialable address for a local test network":
    let disco = setupServiceDiscoveryNode(services = @[makeServiceInfo("service")])
    disco.switch.peerStore.allowUndialableAddrs = true

    let wildcard = ma("/ip4/0.0.0.0/tcp/60000")
    disco.switch.peerInfo.addrs = @[wildcard]

    let rec = disco.record()
    check rec.isOk()
    let xprAddrs = rec.get().data.addresses
    check:
      xprAddrs.len == 1
      xprAddrs[0].address == wildcard

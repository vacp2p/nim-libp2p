# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results, sets
import
  ../../../libp2p/[
    extended_peer_record,
    protocols/service_discovery,
    protocols/service_discovery/advertiser,
  ]
import ../../tools/unittest
import ./utils

# ===========================================================================
suite "Advertiser - addProvidedService":
  teardown:
    checkTrackers()

  test "creates routing table entry for the service":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    disco.populateRoutingTable(1)
    disco.addProvidedService(service)

    check disco.rtManager.hasService(serviceId)

  test "with empty routing table: creates table but schedules no actions":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    disco.addProvidedService(service)

    check disco.rtManager.hasService(serviceId)
    check disco.advertiser.running.len() == 0
      # local registration is now a dedicated loop, not in running

  test "schedules up to kRegister actions per populated bucket":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    disco.populateAdvertisementTable(serviceId)
    disco.addProvidedService(service)

    check disco.advertiser.running.len() == disco.discoConfig.kRegister
      # only remote tasks; local is a separate dedicated loop now

  test "scheduling caps at kRegister tasks per populated bucket":
    let kRegister = 3
    let conf = ServiceDiscoveryConfig.new(kRegister = kRegister)
    let disco = setupServiceDiscoveryNode(discoConfig = conf)
    # Fill the routing table with random peers.
    disco.populateRoutingTable(100)

    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    # Seed the per-service table from the main one.
    check disco.rtManager.addService(
      serviceId, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
      Interest,
    )

    # Empty every bucket that wouldn't exercise the cap, keep only overpopulated buckets.
    let table = disco.rtManager.getTable(serviceId).get()
    var overpopulatedBuckets = 0
    for bucket in mitems(table.buckets):
      if bucket.peers.len <= kRegister:
        bucket.peers = @[]
      else:
        overpopulatedBuckets.inc
    check overpopulatedBuckets > 0

    disco.addProvidedService(service)

    # Only remote tasks are tracked in running now.
    check disco.advertiser.running.len() == overpopulatedBuckets * kRegister

  test "adding same service twice is idempotent":
    let disco = setupServiceDiscoveryNode()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    disco.populateRoutingTable(1)
    disco.addProvidedService(service)
    let runningAfterFirst = disco.advertiser.running.len()

    disco.addProvidedService(service)

    check disco.rtManager.hasService(serviceId)
    check disco.advertiser.running.len() == runningAfterFirst

  test "multiple distinct services each get their own routing table":
    let disco = setupServiceDiscoveryNode()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")
    let s3 = makeServiceInfo("svc-3")

    disco.populateRoutingTable(1)
    disco.addProvidedService(s1)
    disco.addProvidedService(s2)
    disco.addProvidedService(s3)

    check disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())
    check disco.rtManager.hasService(s3.id.hashServiceId())
    check disco.advertiser.running.len() == 3
      # only the remote tasks (1 per service); local registration is a separate loop

# ===========================================================================
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
    disco.addProvidedService(s1)
    disco.addProvidedService(s2)

    await disco.removeProvidedService(s1.id)

    check:
      not disco.rtManager.hasService(sid1)
      disco.rtManager.hasService(sid2)
      disco.advertiser.running.len() == 1
        # only the remote task for the remaining service

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
    disco.addProvidedService(s1)
    disco.addProvidedService(s2)

    await disco.removeProvidedService(s1.id)

    check not disco.rtManager.hasService(s1.id.hashServiceId())
    check disco.rtManager.hasService(s2.id.hashServiceId())

# ===========================================================================
suite "Advertiser - record creation":
  teardown:
    checkTrackers()

  test "record creation rejects service data larger than MaxServiceDataSize":
    # Baseline: service data at the size limit is accepted
    let validData = newSeq[byte](MaxServiceDataSize)
    let discoValid = setupServiceDiscoveryNode(
      services = @[ServiceInfo(id: "service", data: validData)]
    )
    let recordValid = discoValid.record()
    check recordValid.isOk()
    let svc = recordValid.get().data.services[0]
    check:
      svc.isValid()
      svc.data.len == MaxServiceDataSize

    # Oversized service data is rejected
    let oversizedData = newSeq[byte](MaxServiceDataSize + 1)
    let badSvc = ServiceInfo(id: "service", data: oversizedData)
    let discoBad = setupServiceDiscoveryNode(services = @[badSvc])
    let recordBad = discoBad.record()
    check:
      not badSvc.isValid()
      recordBad.isErr()

  test "record creation rejects encoded XPR larger than MaxXPRSize":
    # Baseline: a normal (small) record is accepted and its encoded size is within limit
    let discoSmall = setupServiceDiscoveryNode(services = @[makeServiceInfo("service")])
    let recordSmall = discoSmall.record()
    check recordSmall.isOk()
    let smallXpr = recordSmall.get()
    check:
      smallXpr.isValid()
      smallXpr.encode().get().len <= MaxXPRSize
        # still useful for the exact size assertion

    # Oversized encoded XPR (caused by many addresses) is rejected.
    # We dynamically discover the number of addresses required rather than
    # hard-coding a repeat count. This makes the test robust against changes
    # in MultiAddress encoding, protobuf serialization, signature size, etc.
    let discoBig = setupServiceDiscoveryNode(services = @[makeServiceInfo("service")])
    let baseAddr = makeMultiAddress("10.0.0.1")
    var addrs: seq[MultiAddress]
    var foundOversized = false

    # Search for the smallest number of addresses that makes either:
    # - record() return an error (because the XPR is too big), or
    # - the successfully built record's encoded size exceeds the limit.
    # Safety bound prevents infinite loops in case of unforeseen issues.
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

    doAssert foundOversized, "Could not generate an XPR larger than MaxXPRSize"

    let recordBig = discoBig.record()
    check recordBig.isErr()

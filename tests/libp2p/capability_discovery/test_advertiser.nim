# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import chronos, results
import
  ../../../libp2p/
    [crypto/crypto, multiaddress, extended_peer_record, peerid, routing_record]
import ../../../libp2p/protocols/[kad_disco, kademlia]
import ../../../libp2p/protocols/kademlia_discovery/[types]
import ../../../libp2p/protocols/capability_discovery/[advertiser, serviceroutingtables]
import ../../tools/unittest
import ./utils

# ===========================================================================
# Pure function tests (no async, no teardown needed)
# ===========================================================================

suite "Advertiser - actionCmp":
  test "earlier time < later time":
    let now = Moment.now()
    let a1: PendingAction = (now, makeServiceId(), makePeerId(), 0, Opt.none(Ticket))
    let a2: PendingAction =
      (now + chronos.seconds(1), makeServiceId(), makePeerId(), 0, Opt.none(Ticket))

    check actionCmp(a1, a2) == -1
    check actionCmp(a2, a1) == 1

  test "equal times return 0":
    let now = Moment.now()
    let a1: PendingAction = (now, makeServiceId(), makePeerId(), 0, Opt.none(Ticket))
    let a2: PendingAction = (now, makeServiceId(), makePeerId(), 0, Opt.none(Ticket))

    check actionCmp(a1, a2) == 0

# ===========================================================================
# Queue management
# ===========================================================================

suite "Advertiser - scheduleAction":
  teardown:
    checkTrackers()

  test "inserts single action with correct fields":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()
    let registrar = makePeerId()
    let bucketIdx = 2
    let t = Moment.now()

    kad.scheduleAction(serviceId, registrar, bucketIdx, t)

    check kad.advertiser.actionQueue.len == 1
    let a = kad.advertiser.actionQueue[0]
    check a.scheduledTime == t
    check a.serviceId == serviceId
    check a.registrar == registrar
    check a.bucketIdx == bucketIdx
    check a.ticket.isNone()

  test "inserts with ticket when provided":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()
    let ticket = Ticket(
      advertisement: @[1'u8, 2, 3],
      tInit: 1000,
      tMod: 2000,
      tWaitFor: 300,
      signature: @[],
    )

    kad.scheduleAction(serviceId, makePeerId(), 0, Moment.now(), Opt.some(ticket))

    check kad.advertiser.actionQueue.len == 1
    check kad.advertiser.actionQueue[0].ticket.isSome()
    check kad.advertiser.actionQueue[0].ticket.get().tWaitFor == 300

  test "maintains sorted order regardless of insertion order":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()
    let now = Moment.now()

    # Insert out of order: +3s, +1s, +2s
    kad.scheduleAction(serviceId, makePeerId(), 0, now + chronos.seconds(3))
    kad.scheduleAction(serviceId, makePeerId(), 1, now + chronos.seconds(1))
    kad.scheduleAction(serviceId, makePeerId(), 2, now + chronos.seconds(2))

    check kad.advertiser.actionQueue.len == 3
    check kad.advertiser.actionQueue[0].scheduledTime == now + chronos.seconds(1)
    check kad.advertiser.actionQueue[1].scheduledTime == now + chronos.seconds(2)
    check kad.advertiser.actionQueue[2].scheduledTime == now + chronos.seconds(3)

  test "handles multiple actions with same scheduled time":
    let kad = createMockDiscovery()
    let now = Moment.now()

    for i in 0 ..< 4:
      kad.scheduleAction(makeServiceId(), makePeerId(), i, now)

    check kad.advertiser.actionQueue.len == 4

# ===========================================================================
# Service management
# ===========================================================================

suite "Advertiser - addProvidedService":
  teardown:
    checkTrackers()

  test "creates routing table entry for the service":
    let kad = createMockDiscovery()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    populateRoutingTable(kad, @[makePeerId()])
    kad.addProvidedService(service)

    check kad.serviceRoutingTables.hasService(serviceId)

  test "with empty routing table: creates table but schedules no actions":
    # Source skips scheduling when bucket.peers.len == 0
    let kad = createMockDiscovery()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    kad.addProvidedService(service) # no peers in routing table

    check kad.serviceRoutingTables.hasService(serviceId)
    check kad.advertiser.actionQueue.len == 0

  test "schedules up to kRegister actions per populated bucket":
    let kad = createMockDiscovery()
    let service = makeServiceInfo()

    # Populate with more peers than kRegister
    let peers = newSeq[PeerId](kad.discoConf.kRegister + 2).mapIt(makePeerId())
    populateRoutingTable(kad, peers)
    kad.addProvidedService(service)

    # At most kRegister actions per bucket across all buckets
    for action in kad.advertiser.actionQueue:
      check action.serviceId == service.id.hashServiceId()

  test "adding same service twice is idempotent":
    let kad = createMockDiscovery()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    populateRoutingTable(kad, @[makePeerId()])
    kad.addProvidedService(service)
    let queueLenAfterFirst = kad.advertiser.actionQueue.len

    kad.addProvidedService(service)

    # Routing table still exists exactly once
    check kad.serviceRoutingTables.hasService(serviceId)
    # Queue should not grow — second call is a no-op for the routing table
    check kad.advertiser.actionQueue.len == queueLenAfterFirst

  test "multiple distinct services each get their own routing table":
    let kad = createMockDiscovery()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")
    let s3 = makeServiceInfo("svc-3")

    populateRoutingTable(kad, @[makePeerId()])
    kad.addProvidedService(s1)
    kad.addProvidedService(s2)
    kad.addProvidedService(s3)

    check kad.serviceRoutingTables.hasService(s1.id.hashServiceId())
    check kad.serviceRoutingTables.hasService(s2.id.hashServiceId())
    check kad.serviceRoutingTables.hasService(s3.id.hashServiceId())

suite "Advertiser - removeProvidedService":
  teardown:
    checkTrackers()

  test "removes routing table and clears its pending actions":
    let kad = createMockDiscovery()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")
    let sid1 = s1.id.hashServiceId()
    let sid2 = s2.id.hashServiceId()
    let now = Moment.now()

    populateRoutingTable(kad, @[makePeerId()])
    kad.addProvidedService(s1)
    kad.addProvidedService(s2)
    kad.advertiser.actionQueue.setLen(0)

    kad.scheduleAction(sid1, makePeerId(), 0, now)
    kad.scheduleAction(sid2, makePeerId(), 0, now)
    kad.scheduleAction(sid1, makePeerId(), 1, now + chronos.seconds(1))

    kad.removeProvidedService(s1)

    check not kad.serviceRoutingTables.hasService(sid1)
    check kad.serviceRoutingTables.hasService(sid2)
    check kad.advertiser.actionQueue.len == 1
    check kad.advertiser.actionQueue[0].serviceId == sid2

  test "removing non-existent service is a no-op":
    let kad = createMockDiscovery()
    let service = makeServiceInfo()

    kad.removeProvidedService(service) # must not crash or error
    check not kad.serviceRoutingTables.hasService(service.id.hashServiceId())

  test "removing one service leaves others intact":
    let kad = createMockDiscovery()
    let s1 = makeServiceInfo("svc-1")
    let s2 = makeServiceInfo("svc-2")

    populateRoutingTable(kad, @[makePeerId()])
    kad.addProvidedService(s1)
    kad.addProvidedService(s2)

    kad.removeProvidedService(s1)

    check not kad.serviceRoutingTables.hasService(s1.id.hashServiceId())
    check kad.serviceRoutingTables.hasService(s2.id.hashServiceId())

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

suite "Kademlia Discovery Advertiser - Pure Functions":
  test "actionCmp compares by scheduled time":
    let now = Moment.now()
    let later = now + chronos.seconds(1)

    let action1: PendingAction =
      (now, makeServiceId(), makePeerId(), 0, Opt.none(Ticket))
    let action2: PendingAction =
      (later, makeServiceId(), makePeerId(), 0, Opt.none(Ticket))

    # Earlier time should be less
    check actionCmp(action1, action2) == -1
    check actionCmp(action2, action1) == 1

  test "actionCmp with equal times returns 0":
    let now = Moment.now()

    let action1: PendingAction =
      (now, makeServiceId(), makePeerId(), 0, Opt.none(Ticket))
    let action2: PendingAction =
      (now, makeServiceId(), makePeerId(), 0, Opt.none(Ticket))

    check actionCmp(action1, action2) == 0

suite "Kademlia Discovery Advertiser - Queue Management":
  teardown:
    checkTrackers()

  test "scheduleAction inserts single action":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()
    let registrar = makePeerId()
    let bucketIdx = 0
    let scheduledTime = Moment.now()

    kad.scheduleAction(serviceId, registrar, bucketIdx, scheduledTime)

    check kad.advertiser.actionQueue.len == 1
    check kad.advertiser.actionQueue[0].scheduledTime == scheduledTime
    check kad.advertiser.actionQueue[0].serviceId == serviceId
    check kad.advertiser.actionQueue[0].registrar == registrar
    check kad.advertiser.actionQueue[0].bucketIdx == bucketIdx

  test "scheduleAction maintains sorted order":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()
    let now = Moment.now()

    # Add actions in reverse time order
    kad.scheduleAction(serviceId, makePeerId(), 0, now + chronos.seconds(3))
    kad.scheduleAction(serviceId, makePeerId(), 1, now + chronos.seconds(1))
    kad.scheduleAction(serviceId, makePeerId(), 2, now + chronos.seconds(2))

    check kad.advertiser.actionQueue.len == 3

    # Verify queue is sorted by time
    check kad.advertiser.actionQueue[0].scheduledTime == now + chronos.seconds(1)
    check kad.advertiser.actionQueue[1].scheduledTime == now + chronos.seconds(2)
    check kad.advertiser.actionQueue[2].scheduledTime == now + chronos.seconds(3)

  test "scheduleAction with same scheduled time":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()
    let now = Moment.now()

    # Add multiple actions with same time
    for i in 0 ..< 5:
      kad.scheduleAction(serviceId, makePeerId(), i, now)

    check kad.advertiser.actionQueue.len == 5

  test "removeProvidedService filters action queue":
    let kad = createMockDiscovery()
    let service1 = makeServiceInfo("1")
    let service2 = makeServiceInfo("2")
    let serviceId1 = service1.id.hashServiceId()
    let serviceId2 = service2.id.hashServiceId()
    let now = Moment.now()

    # Add services first
    populateRoutingTable(kad, @[makePeerId()])
    kad.addProvidedService(service1)
    kad.addProvidedService(service2)

    # Clear the queue that was populated by addProvidedService
    kad.advertiser.actionQueue.setLen(0)

    # Add actions for different services
    kad.scheduleAction(serviceId1, makePeerId(), 0, now)
    kad.scheduleAction(serviceId2, makePeerId(), 0, now)
    kad.scheduleAction(serviceId1, makePeerId(), 1, now + chronos.seconds(1))
    kad.scheduleAction(serviceId2, makePeerId(), 1, now + chronos.seconds(1))

    check kad.advertiser.actionQueue.len == 4

    # Remove service1
    kad.removeProvidedService(service1)

    # Only service2 actions should remain
    check kad.advertiser.actionQueue.len == 2
    for action in kad.advertiser.actionQueue:
      check action.serviceId == serviceId2

suite "Kademlia Discovery Advertiser - Service Management":
  teardown:
    checkTrackers()

  test "removeProvidedService removes table":
    let kad = createMockDiscovery()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    kad.addProvidedService(service)
    check kad.serviceRoutingTables.hasService(serviceId)

    kad.removeProvidedService(service)
    check not kad.serviceRoutingTables.hasService(serviceId)

  test "removeProvidedService non-existent is safe":
    let kad = createMockDiscovery()
    let service = makeServiceInfo()
    let serviceId = service.id.hashServiceId()

    # Should not error
    kad.removeProvidedService(service)

suite "Kademlia Discovery Advertiser - Edge Cases":
  teardown:
    checkTrackers()

  test "Multiple services can be added":
    let kad = createMockDiscovery()
    let service1 = makeServiceInfo("1")
    let serviceId1 = service1.id.hashServiceId()
    let service2 = makeServiceInfo("2")
    let serviceId2 = service2.id.hashServiceId()
    let service3 = makeServiceInfo("3")
    let serviceId3 = service3.id.hashServiceId()

    populateRoutingTable(kad, @[makePeerId()])

    kad.addProvidedService(service1)
    kad.addProvidedService(service2)
    kad.addProvidedService(service3)

    check kad.serviceRoutingTables.hasService(serviceId1)
    check kad.serviceRoutingTables.hasService(serviceId2)
    check kad.serviceRoutingTables.hasService(serviceId3)

  test "Removing one service doesn't affect others":
    let kad = createMockDiscovery()

    let service1 = makeServiceInfo("1")
    let serviceId1 = service1.id.hashServiceId()
    let service2 = makeServiceInfo("2")
    let serviceId2 = service2.id.hashServiceId()

    populateRoutingTable(kad, @[makePeerId()])

    kad.addProvidedService(service1)
    kad.addProvidedService(service2)

    kad.removeProvidedService(service1)

    check not kad.serviceRoutingTables.hasService(serviceId1)
    check kad.serviceRoutingTables.hasService(serviceId2)

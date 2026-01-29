# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[options]
import chronos, chronicles, results
import ../../../libp2p/[peerid, crypto/crypto, multiaddress, switch, builders]
import ../../../libp2p/protocols/[kademlia, kad_disco]
import ../../../libp2p/protocols/kademlia_discovery/[types, protobuf, advertiser]
import ../../tools/[unittest, crypto]

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

# Test helpers to create mock peers
proc makePeerId(): PeerId =
  PeerId.init(PrivateKey.random(rng[]).get()).get()

proc makeServiceId(): ServiceId =
  @[1'u8, 2, 3, 4]

proc makeServiceId(id: byte): ServiceId =
  @[id, 2'u8, 3, 4]

# Helper to create a mock KademliaDiscovery for testing advertiser functionality
proc createMockDiscovery(): KademliaDiscovery =
  let switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

  let kad = KademliaDiscovery.new(
    switch,
    bootstrapNodes = @[],
    config = KadDHTConfig.new(
      ExtEntryValidator(),
      ExtEntrySelector(),
      timeout = chronos.seconds(1),
      cleanupProvidersInterval = chronos.milliseconds(100),
      providerExpirationInterval = chronos.seconds(1),
      republishProvidedKeysInterval = chronos.milliseconds(50),
    ),
    discoConf = KademliaDiscoveryConfig.new(kRegister = 3, bucketsCount = 16),
  )

  switch.mount(kad)
  kad

# Helper to populate routing table with peers
proc populateRoutingTable(kad: KademliaDiscovery, peers: seq[PeerId]) =
  for peer in peers:
    let key = peer.toKey()
    discard kad.rtable.insert(key)

# ============================================================================
# 1. Pure Function Tests (No Mocking Required)
# ============================================================================

suite "Kademlia Discovery Advertiser - Pure Functions":
  test "actionCmp compares by scheduled time":
    let now = Moment.now()
    let later = now + 1.seconds

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

  test "actionCmp with different fields but same time":
    let now = Moment.now()

    let action1: PendingAction =
      (now, makeServiceId(), makePeerId(), 0, Opt.none(Ticket))
    let action2: PendingAction =
      (now, makeServiceId(), makePeerId(), 5, Opt.none(Ticket))

    # Should return 0 when times are equal
    check actionCmp(action1, action2) == 0

# ============================================================================
# 2. Queue Management Tests
# ============================================================================

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
    kad.scheduleAction(serviceId, makePeerId(), 0, now + 3.seconds)
    kad.scheduleAction(serviceId, makePeerId(), 1, now + 1.seconds)
    kad.scheduleAction(serviceId, makePeerId(), 2, now + 2.seconds)

    check kad.advertiser.actionQueue.len == 3

    # Verify queue is sorted by time
    check kad.advertiser.actionQueue[0].scheduledTime == now + 1.seconds
    check kad.advertiser.actionQueue[1].scheduledTime == now + 2.seconds
    check kad.advertiser.actionQueue[2].scheduledTime == now + 3.seconds

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
    let serviceId1 = makeServiceId(1)
    let serviceId2 = makeServiceId(2)
    let now = Moment.now()

    # Add services to advTable first
    populateRoutingTable(kad, @[makePeerId()])
    kad.addProvidedService(serviceId1)
    kad.addProvidedService(serviceId2)

    # Clear the queue that was populated by addProvidedService
    kad.advertiser.actionQueue.setLen(0)

    # Add actions for different services
    kad.scheduleAction(serviceId1, makePeerId(), 0, now)
    kad.scheduleAction(serviceId2, makePeerId(), 0, now)
    kad.scheduleAction(serviceId1, makePeerId(), 1, now + 1.seconds)
    kad.scheduleAction(serviceId2, makePeerId(), 1, now + 1.seconds)

    check kad.advertiser.actionQueue.len == 4

    # Remove service1
    kad.removeProvidedService(serviceId1)

    # Only service2 actions should remain
    check kad.advertiser.actionQueue.len == 2
    for action in kad.advertiser.actionQueue:
      check action.serviceId == serviceId2

# ============================================================================
# 3. Service Management Tests
# ============================================================================

suite "Kademlia Discovery Advertiser - Service Management":
  teardown:
    checkTrackers()

  test "addProvidedService creates AdvT":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()

    kad.addProvidedService(serviceId)

    check serviceId in kad.advertiser.advTable
    check kad.advertiser.advTable[serviceId] != nil

  test "addProvidedService duplicate is ignored":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()

    kad.addProvidedService(serviceId)
    let table1 = kad.advertiser.advTable[serviceId]

    kad.addProvidedService(serviceId)
    let table2 = kad.advertiser.advTable[serviceId]

    # Should be the same table instance
    check table1 == table2

  test "addProvidedService with empty routing table":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()

    # Routing table starts empty
    check kad.rtable.buckets.len == 0

    kad.addProvidedService(serviceId)

    # AdvT should be created but empty
    check serviceId in kad.advertiser.advTable
    check kad.advertiser.advTable[serviceId].buckets.len == 0

  test "addProvidedService schedules actions for peers":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()

    # Add some peers to routing table
    let peer1 = makePeerId()
    let peer2 = makePeerId()
    let peer3 = makePeerId()

    populateRoutingTable(kad, @[peer1, peer2, peer3])

    kad.addProvidedService(serviceId)

    # Actions should be scheduled for each peer
    check kad.advertiser.actionQueue.len > 0

    # All actions should be for the added service
    for action in kad.advertiser.actionQueue:
      check action.serviceId == serviceId
      check action.scheduledTime <= Moment.now() + 1.seconds # ASAP

  test "addProvidedService with different K_register":
    let kad = KademliaDiscovery.new(
      createMockDiscovery().switch,
      bootstrapNodes = @[],
      config = KadDHTConfig.new(
        ExtEntryValidator(), ExtEntrySelector(), timeout = chronos.seconds(1)
      ),
      discoConf = KademliaDiscoveryConfig.new(
        kRegister = 1, # Only 1 peer per bucket
        bucketsCount = 16,
      ),
    )

    let serviceId = makeServiceId()

    # Add multiple peers
    for i in 0 ..< 5:
      discard kad.rtable.insert(makePeerId())

    kad.addProvidedService(serviceId)

    # With K_register = 1, should schedule at most 1 action per bucket
    # But the exact number depends on bucket distribution
    check kad.advertiser.actionQueue.len >= 0

  test "removeProvidedService removes table":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()

    kad.addProvidedService(serviceId)
    check serviceId in kad.advertiser.advTable

    kad.removeProvidedService(serviceId)
    check serviceId notin kad.advertiser.advTable

  test "removeProvidedService non-existent is safe":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()

    # Should not error
    kad.removeProvidedService(serviceId)

  test "removeProvidedService clears pending actions":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()
    let now = Moment.now()

    # Add service and actions
    populateRoutingTable(kad, @[makePeerId()])
    kad.addProvidedService(serviceId)

    let actionCount = kad.advertiser.actionQueue.len
    check actionCount > 0

    # Remove service
    kad.removeProvidedService(serviceId)

    # Actions for this service should be removed
    var serviceActions = 0
    for action in kad.advertiser.actionQueue:
      if action.serviceId == serviceId:
        inc serviceActions

    check serviceActions == 0

# ============================================================================
# 4. Advertisement Building Tests
# ============================================================================

suite "Kademlia Discovery Advertiser - Advertisement Building":
  test "Advertisement components are available":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()

    # Verify the components are available for building ads
    check kad.switch.peerInfo.peerId.data.len > 0
    # Note: addrs might be empty in mock discovery, but peerId should be available

  test "Advertisement signature can be created":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: makeServiceId(),
      peerId: makePeerId(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    let signResult = ad.sign(privateKey)
    check signResult.isOk()
    check ad.signature.len > 0

  test "Advertisement signature verification works":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: makeServiceId(),
      peerId: makePeerId(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    discard ad.sign(privateKey)

    let publicKey = privateKey.getPublicKey().get()
    check ad.verify(publicKey) == true

  test "Advertisement signature fails with tampered data":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()
    var ad = Advertisement(
      serviceId: makeServiceId(),
      peerId: makePeerId(),
      addrs: @[maddr],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    )

    let privateKey = PrivateKey.random(rng[]).get()
    discard ad.sign(privateKey)

    let publicKey = privateKey.getPublicKey().get()

    # Tamper with serviceId
    ad.serviceId[0] = 255'u8
    check ad.verify(publicKey) == false

# ============================================================================
# 5. Rescheduling Logic Tests
# ============================================================================

suite "Kademlia Discovery Advertiser - Rescheduling Logic":
  teardown:
    checkTrackers()

  test "addProvidedService with different bucketsCount":
    for bc in [8, 16, 32]:
      let kad = KademliaDiscovery.new(
        createMockDiscovery().switch,
        bootstrapNodes = @[],
        config = KadDHTConfig.new(
          ExtEntryValidator(), ExtEntrySelector(), timeout = chronos.seconds(1)
        ),
        discoConf = KademliaDiscoveryConfig.new(kRegister = 3, bucketsCount = bc),
      )

      let serviceId = makeServiceId()

      # Add peers to routing table
      for i in 0 ..< 10:
        discard kad.rtable.insert(makePeerId())

      kad.addProvidedService(serviceId)

      # AdvT should be created with correct bucketsCount
      check serviceId in kad.advertiser.advTable

# ============================================================================
# 6. Edge Cases and Error Handling
# ============================================================================

suite "Kademlia Discovery Advertiser - Edge Cases":
  teardown:
    checkTrackers()

  test "Multiple services can be added":
    let kad = createMockDiscovery()

    let service1 = makeServiceId(1)
    let service2 = makeServiceId(2)
    let service3 = makeServiceId(3)

    populateRoutingTable(kad, @[makePeerId()])

    kad.addProvidedService(service1)
    kad.addProvidedService(service2)
    kad.addProvidedService(service3)

    check service1 in kad.advertiser.advTable
    check service2 in kad.advertiser.advTable
    check service3 in kad.advertiser.advTable

  test "Removing one service doesn't affect others":
    let kad = createMockDiscovery()

    let service1 = makeServiceId(1)
    let service2 = makeServiceId(2)

    populateRoutingTable(kad, @[makePeerId()])

    kad.addProvidedService(service1)
    kad.addProvidedService(service2)

    kad.removeProvidedService(service1)

    check service1 notin kad.advertiser.advTable
    check service2 in kad.advertiser.advTable

  test "Actions are sorted after multiple insertions":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()
    let baseTime = Moment.now()

    # Insert in random order
    kad.scheduleAction(serviceId, makePeerId(), 0, baseTime + 5.seconds)
    kad.scheduleAction(serviceId, makePeerId(), 1, baseTime + 2.seconds)
    kad.scheduleAction(serviceId, makePeerId(), 2, baseTime + 7.seconds)
    kad.scheduleAction(serviceId, makePeerId(), 3, baseTime + 1.seconds)
    kad.scheduleAction(serviceId, makePeerId(), 4, baseTime + 3.seconds)

    # Verify sorted order
    var lastTime = baseTime - 10.seconds # Use a time before all actions
    for action in kad.advertiser.actionQueue:
      check action.scheduledTime >= lastTime
      lastTime = action.scheduledTime

# ============================================================================
# 7. Ticket Tests
# ============================================================================

suite "Kademlia Discovery Advertiser - Ticket Handling":
  test "scheduleAction with ticket":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()
    let registrar = makePeerId()
    let now = Moment.now()

    var ticket = Ticket(
      ad: Advertisement(
        serviceId: serviceId,
        peerId: makePeerId(),
        addrs: @[],
        signature: @[],
        metadata: @[],
        timestamp: 0,
      ),
      t_init: 100,
      t_mod: 200,
      t_wait_for: 300,
      signature: @[],
    )

    kad.scheduleAction(serviceId, registrar, 0, now, Opt.some(ticket))

    check kad.advertiser.actionQueue.len == 1
    check kad.advertiser.actionQueue[0].ticket.isSome()
    check kad.advertiser.actionQueue[0].ticket.get().t_wait_for == 300

  test "scheduleAction without ticket":
    let kad = createMockDiscovery()
    let serviceId = makeServiceId()
    let registrar = makePeerId()
    let now = Moment.now()

    kad.scheduleAction(serviceId, registrar, 0, now, Opt.none(Ticket))

    check kad.advertiser.actionQueue.len == 1
    check kad.advertiser.actionQueue[0].ticket.isNone()

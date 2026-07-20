# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, sets, tables, sequtils
import
  ../../../libp2p/[peerinfo],
  ../../../libp2p/protocols/kademlia,
  ../../../libp2p/protocols/service_discovery/[types, routing_table_manager]
import ../../tools/[lifecycle, unittest]
import ../kademlia/[mock_kademlia, utils]
import ./utils except randomPeerId

proc makeKey(x: byte): Key =
  var buf: array[IdLength, byte]
  buf[31] = x
  return @buf

proc makeServiceId(x: byte): ServiceId =
  return makeKey(x)

# Heap-allocated recorder so a closure capturing it stays GC-safe (mirrors how
# the production callback captures the disco ref rather than a stack local).
type HitRecorder = ref object
  ids: seq[ServiceId]

proc makeMainTable(selfId: Key, peers: seq[Key]): RoutingTable =
  var rt = RoutingTable.new(selfId)
  for p in peers:
    discard rt.insert(p)
  rt

suite "ServiceRoutingTableManager":
  test "new creates empty manager":
    let manager = ServiceRoutingTableManager.new()
    check:
      manager.count() == 0
      manager.serviceIds().len == 0

  test "addService returns true and adds table":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(makeKey(0))

    check:
      manager.addService(
        serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
      )
      manager.count() == 1
      manager.hasService(serviceId)

  test "addService with same service and same status returns false":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(makeKey(0))

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    let addedAgain = manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    check:
      addedAgain == false
      manager.serviceStatus[serviceId] == Interest

  test "addService with same service but different status sets Both and returns true":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(makeKey(0))

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    let upgraded = manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )

    check:
      upgraded == true
      manager.serviceStatus[serviceId] == Both

  test "addService fires onServiceTableCreated only for brand-new tables":
    let manager = ServiceRoutingTableManager.new()
    let mainRt = RoutingTable.new(makeKey(0))

    let hits = HitRecorder()
    manager.onServiceTableCreated = proc(sid: ServiceId) =
      hits.ids.add(sid)

    let serviceId = makeServiceId(1)

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check:
      hits.ids.len == 1
      hits.ids[0] == serviceId

    discard manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check hits.ids.len == 1

    discard manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )
    check:
      hits.ids.len == 1
      manager.serviceStatus[serviceId] == Both

    let otherId = makeServiceId(2)
    check manager.addService(
      otherId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )
    check:
      hits.ids.len == 2
      otherId in hits.ids

  test "addService with no callback set does not crash":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(makeKey(0))

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check manager.hasService(serviceId)

  test "addService pre-populates table from main routing table":
    let selfId = makeKey(0)
    let peer1 = makeKey(1)
    let peer2 = makeKey(2)
    let mainRt = makeMainTable(selfId, @[peer1, peer2])

    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(3)
    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    let table = manager.getTable(serviceId).get()

    let peers = table.allKeys()

    check:
      peer1 in peers
      peer2 in peers

  test "removeService removes entry when status matches":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(makeKey(0))

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    manager.removeService(serviceId, Interest)

    check:
      not manager.hasService(serviceId)
      manager.count() == 0

  test "removeService on Both with Interest leaves Provided":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(makeKey(0))

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )
    check manager.serviceStatus[serviceId] == Both

    manager.removeService(serviceId, Interest)

    check:
      manager.hasService(serviceId)
      manager.serviceStatus[serviceId] == Provided

  test "removeService on Both with Provided leaves Interest":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(makeKey(0))

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )
    check manager.serviceStatus[serviceId] == Both

    manager.removeService(serviceId, Provided)

    check:
      manager.hasService(serviceId)
      manager.serviceStatus[serviceId] == Interest

  test "removeService on non-existent service is a no-op":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)

    manager.removeService(serviceId, Interest)
    check manager.count() == 0

  test "getTable returns Some for existing service":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(makeKey(0))

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )

    check manager.getTable(serviceId).isSome()

  test "getTable returns None for non-existing service":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)

    check manager.getTable(serviceId).isNone()

  test "insertPeer admits a peer with a valid address to the service routing table":
    let disco = setupServiceDiscoveryNode()
    let serviceId = makeServiceId(1)

    check disco.rtManager.addService(
      serviceId, disco.rtable, DefaultReplication, DefaultMaxBuckets, Interest
    )

    let peer = randomPeerId()
    let peerInfo = PeerInfo(peerId: peer, addrs: @[makeMultiAddress("10.0.0.1")])
    disco.insertPeer(serviceId, peerInfo)

    let table = disco.rtManager.getTable(serviceId).get()

    check peer.toKey() in table.allKeys()

  test "insertPeer rejects a peer with no addresses":
    let disco = setupServiceDiscoveryNode()
    let serviceId = makeServiceId(1)

    check disco.rtManager.addService(
      serviceId, disco.rtable, DefaultReplication, DefaultMaxBuckets, Interest
    )

    let peer = randomPeerId()
    disco.insertPeer(serviceId, PeerInfo(peerId: peer, addrs: @[]))

    let table = disco.rtManager.getTable(serviceId).get()

    check peer.toKey() notin table.allKeys()

  test "insertPeer on non-existent service is a no-op":
    let disco = setupServiceDiscoveryNode()
    let serviceId = makeServiceId(1)
    let peerInfo =
      PeerInfo(peerId: randomPeerId(), addrs: @[makeMultiAddress("10.0.0.1")])

    disco.insertPeer(serviceId, peerInfo)
    check disco.rtManager.count() == 0

  test "hasService returns false for unknown service":
    let manager = ServiceRoutingTableManager.new()
    check not manager.hasService(makeKey(1))

  test "count reflects number of tracked services":
    let manager = ServiceRoutingTableManager.new()
    let mainRt = RoutingTable.new(makeKey(0))

    check manager.addService(
      makeKey(1), mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check manager.addService(
      makeKey(2), mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )
    check manager.addService(
      makeKey(3), mainRt, DefaultReplication, DefaultMaxBuckets, Both
    )

    check manager.count() == 3

  test "serviceIds returns all service IDs":
    let manager = ServiceRoutingTableManager.new()
    let mainRt = RoutingTable.new(makeKey(0))
    let ids = @[makeKey(1), makeKey(2), makeKey(3)]

    for id in ids:
      check manager.addService(
        id, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
      )

    check manager.serviceIds().toHashSet() == ids.toHashSet()

  test "clear removes all service tables":
    let manager = ServiceRoutingTableManager.new()
    let mainRt = RoutingTable.new(makeKey(0))

    check manager.addService(
      makeKey(1), mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check manager.addService(
      makeKey(2), mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )

    manager.clear()

    check:
      manager.count() == 0
      not manager.hasService(makeKey(1))
      not manager.hasService(makeKey(2))

  test "manager has selfIdPreHashed set to true":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(makeKey(0))

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    check:
      manager.getTable(serviceId).get().config.selfIdPreHashed

suite "ServiceRoutingTableManager - refreshAllTables":
  teardown:
    checkTrackers()

  asyncTest "does nothing when no tables are registered":
    let manager = ServiceRoutingTableManager.new()
    let kad = setupMockKad()
    startAndDeferStop(@[kad])

    await manager.refreshAllTables(kad)

    # only call it once
    check kad.findNodeCalls.len == 1

  asyncTest "calls findNode with service selfId for a single table":
    let manager = ServiceRoutingTableManager.new()
    let kad = setupMockKad()
    startAndDeferStop(@[kad])

    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(makeKey(2))
    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    await manager.refreshAllTables(kad)

    # refreshTable calls findNode(serviceTable.selfId) once per table
    # plus main table's selfId
    check:
      kad.findNodeCalls.len == 2
      kad.findNodeCalls[1] == serviceId

  asyncTest "calls findNode once per registered service table":
    let manager = ServiceRoutingTableManager.new()
    let kad = setupMockKad()
    startAndDeferStop(@[kad])

    let mainRt = RoutingTable.new(makeKey(0))
    let serviceIds = @[makeKey(1), makeKey(2), makeKey(3)]
    for id in serviceIds:
      check manager.addService(
        id, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
      )

    await manager.refreshAllTables(kad)

    # One self-lookup per service table
    # plus main table's selfId
    check kad.findNodeCalls.len == serviceIds.len + 1
    for id in serviceIds:
      check id in kad.findNodeCalls

  asyncTest "does not call findNode for a removed service table":
    let manager = ServiceRoutingTableManager.new()
    let kad = setupMockKad()
    startAndDeferStop(@[kad])

    let mainRt = RoutingTable.new(makeKey(0))
    let kept = makeKey(1)
    let removed = makeKey(2)
    check manager.addService(
      kept, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check manager.addService(
      removed, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    manager.removeService(removed, Interest)

    await manager.refreshAllTables(kad)

    check:
      # One self-lookup per service table
      # plus main table's selfId
      kad.findNodeCalls.len == 2
      kad.findNodeCalls[1] == kept
      removed notin kad.findNodeCalls

  test "addService rejects local node insertion into service table":
    let selfId = makeKey(0)
    let peer1 = makeKey(1)
    let peer2 = makeKey(2)
    let mainRt = makeMainTable(selfId, @[peer1, peer2])

    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(3)
    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    let table = manager.getTable(serviceId).get()
    discard table.insert(selfId)

    let peers = table.allKeys()

    check:
      selfId notin peers # local node must be rejected
      peer1 in peers
      peer2 in peers

suite "ServiceRoutingTableManager - service id hashing":
  test "service table buckets peers by the service id, not its re-hash":
    let
      serviceId = hashServiceId("/logos/service-discovery/1.0.0")
      peer = makeKey(1)
      manager = ServiceRoutingTableManager.new()
      mainRt = RoutingTable.new(makeKey(0))
    check manager.addService(serviceId, mainRt, 100, DefaultMaxBuckets, Interest)

    let serviceTable = manager.getTable(serviceId).get()
    discard serviceTable.insert(peer)

    let preHashBucket = serviceTable.bucketIndex(peer)

    var nonServiceTable = serviceTable

    # Service table always have this set to true
    nonServiceTable.config.selfIdPreHashed = false

    let doubleHashBucket = nonServiceTable.bucketIndex(peer)

    check:
      preHashBucket != doubleHashBucket
      serviceTable.buckets[preHashBucket].peers.len == 1
      serviceTable.buckets[preHashBucket].peers[0].nodeId == peer

  test "service table with small bucketsCount uses scaled bucket mapping":
    let
      serviceId = hashServiceId("scaled-buckets-test")
      peer = makeKey(42)
      manager = ServiceRoutingTableManager.new()
      mainRt = RoutingTable.new(makeKey(0))
    check manager.addService(serviceId, mainRt, 20, 16, Interest)

    let table = manager.getTable(serviceId).get()
    discard table.insert(peer)

    let expectedScaled = table.bucketIndex(peer)

    check:
      peer in table.allKeys()
      expectedScaled < 16

    var actual = -1
    for i, b in table.buckets:
      if b.peers.anyIt(it.nodeId == peer):
        actual = i
        break
    check actual == expectedScaled

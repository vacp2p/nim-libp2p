# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, sets
import
  ../../../libp2p/protocols/kademlia,
  ../../../libp2p/protocols/service_discovery/[types, routing_table_manager]
import ../../tools/[lifecycle, unittest]
import ../kademlia/[mock_kademlia, utils]

proc makeKey(x: byte): Key =
  var buf: array[IdLength, byte]
  buf[31] = x
  return @buf

proc makeServiceId(x: byte): ServiceId =
  return makeKey(x)

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

  test "insertPeer adds peer to the service routing table":
    let selfId = makeKey(0)
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let mainRt = RoutingTable.new(selfId)

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    let peerKey = makeKey(2)
    manager.insertPeer(serviceId, peerKey)

    let table = manager.getTable(serviceId).get()

    check peerKey in table.allKeys()

  test "insertPeer on non-existent service is a no-op":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = makeServiceId(1)
    let peerKey = makeKey(2)

    manager.insertPeer(serviceId, peerKey)
    check manager.count() == 0

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

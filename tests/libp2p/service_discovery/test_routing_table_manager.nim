# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results
import
  ../../../libp2p/protocols/kademlia,
  ../../../libp2p/protocols/service_discovery/routing_table_manager
import ../../tools/unittest

proc testKey*(x: byte): Key =
  var buf: array[IdLength, byte]
  buf[31] = x
  return @buf

proc makeMainTable*(selfId: Key, peers: seq[Key]): RoutingTable =
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
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

    check:
      manager.addService(
        serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
      )
      manager.count() == 1
      manager.hasService(serviceId)

  test "addService with same service and same status returns false":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

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
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

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
    let selfId = testKey(0x00)
    let peer1 = testKey(0x01)
    let peer2 = testKey(0x02)
    let mainRt = makeMainTable(selfId, @[peer1, peer2])

    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0xAA)
    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    let table = manager.getTable(serviceId).get()

    var found: seq[Key]
    for bucket in table.buckets:
      for entry in bucket.peers:
        found.add(entry.nodeId)

    check:
      peer1 in found
      peer2 in found

  test "removeService removes entry when status matches":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    manager.removeService(serviceId, Interest)

    check:
      not manager.hasService(serviceId)
      manager.count() == 0

  test "removeService on Both with Interest leaves Provided":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

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
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

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
    let serviceId = testKey(0x99)

    manager.removeService(serviceId, Interest)
    check manager.count() == 0

  test "getTable returns Some for existing service":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )

    check manager.getTable(serviceId).isSome()

  test "getTable returns None for non-existing service":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)

    check manager.getTable(serviceId).isNone()

  test "insertPeer adds peer to the service routing table":
    let selfId = testKey(0x00)
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(selfId)

    check manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    let peerKey = testKey(0x42)
    manager.insertPeer(serviceId, peerKey)

    let tableOpt = manager.getTable(serviceId)
    check tableOpt.isSome()

    var found = false
    for bucket in tableOpt.get().buckets:
      for entry in bucket.peers:
        if entry.nodeId == peerKey:
          found = true
    check found

  test "insertPeer on non-existent service is a no-op":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x99)
    let peerKey = testKey(0x42)

    manager.insertPeer(serviceId, peerKey)
    check manager.count() == 0

  test "hasService returns false for unknown service":
    let manager = ServiceRoutingTableManager.new()
    check not manager.hasService(testKey(0x01))

  test "count reflects number of tracked services":
    let manager = ServiceRoutingTableManager.new()
    let mainRt = RoutingTable.new(testKey(0x00))

    check manager.addService(
      testKey(0x01), mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check manager.addService(
      testKey(0x02), mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )
    check manager.addService(
      testKey(0x03), mainRt, DefaultReplication, DefaultMaxBuckets, Both
    )

    check manager.count() == 3

  test "serviceIds returns all service IDs":
    let manager = ServiceRoutingTableManager.new()
    let mainRt = RoutingTable.new(testKey(0x00))
    let ids = @[testKey(0x01), testKey(0x02), testKey(0x03)]

    for id in ids:
      check manager.addService(
        id, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
      )

    let returned = manager.serviceIds()
    check returned.len == ids.len
    for id in ids:
      check id in returned

  test "clear removes all service tables":
    let manager = ServiceRoutingTableManager.new()
    let mainRt = RoutingTable.new(testKey(0x00))

    check manager.addService(
      testKey(0x01), mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check manager.addService(
      testKey(0x02), mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )

    manager.clear()

    check:
      manager.count() == 0
      not manager.hasService(testKey(0x01))
      not manager.hasService(testKey(0x02))

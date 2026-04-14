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
  asyncTest "new creates empty manager":
    let manager = ServiceRoutingTableManager.new()
    check:
      (await manager.count()) == 0
      (await manager.serviceIds()).len == 0

  asyncTest "addService returns true and adds table":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

    let added = await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    check:
      added == true
      manager.hasService(serviceId)
      (await manager.count()) == 1

  asyncTest "addService with same service and same status returns false":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

    discard await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    let addedAgain = await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    check:
      addedAgain == false
      manager.serviceStatus[serviceId] == Interest

  asyncTest "addService with same service but different status sets Both and returns true":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

    discard await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    let upgraded = await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )

    check:
      upgraded == true
      manager.serviceStatus[serviceId] == Both

  asyncTest "addService pre-populates table from main routing table":
    let selfId = testKey(0x00)
    let peer1 = testKey(0x01)
    let peer2 = testKey(0x02)
    let mainRt = makeMainTable(selfId, @[peer1, peer2])

    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0xAA)
    discard await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    let tableOpt = await manager.getTable(serviceId)
    check tableOpt.isSome()
    let table = tableOpt.get()

    var found: seq[Key]
    for bucket in table.buckets:
      for entry in bucket.peers:
        found.add(entry.nodeId)

    check:
      peer1 in found
      peer2 in found

  asyncTest "removeService removes entry when status matches":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

    discard await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    await manager.removeService(serviceId, Interest)

    check:
      not manager.hasService(serviceId)
      (await manager.count()) == 0

  asyncTest "removeService on Both with Interest leaves Provided":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

    discard await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    discard await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )
    check manager.serviceStatus[serviceId] == Both

    await manager.removeService(serviceId, Interest)

    check:
      manager.hasService(serviceId)
      manager.serviceStatus[serviceId] == Provided

  asyncTest "removeService on Both with Provided leaves Interest":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

    discard await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    discard await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )
    check manager.serviceStatus[serviceId] == Both

    await manager.removeService(serviceId, Provided)

    check:
      manager.hasService(serviceId)
      manager.serviceStatus[serviceId] == Interest

  asyncTest "removeService on non-existent service is a no-op":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x99)

    await manager.removeService(serviceId, Interest)
    check (await manager.count()) == 0

  asyncTest "getTable returns Some for existing service":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(testKey(0x00))

    discard await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )

    check (await manager.getTable(serviceId)).isSome()

  asyncTest "getTable returns None for non-existing service":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)

    check (await manager.getTable(serviceId)).isNone()

  asyncTest "insertPeer adds peer to the service routing table":
    let selfId = testKey(0x00)
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x01)
    let mainRt = RoutingTable.new(selfId)

    discard await manager.addService(
      serviceId, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )

    let peerKey = testKey(0x42)
    await manager.insertPeer(serviceId, peerKey)

    let tableOpt = await manager.getTable(serviceId)
    check tableOpt.isSome()

    var found = false
    for bucket in tableOpt.get().buckets:
      for entry in bucket.peers:
        if entry.nodeId == peerKey:
          found = true
    check found

  asyncTest "insertPeer on non-existent service is a no-op":
    let manager = ServiceRoutingTableManager.new()
    let serviceId = testKey(0x99)
    let peerKey = testKey(0x42)

    await manager.insertPeer(serviceId, peerKey)
    check (await manager.count()) == 0

  asyncTest "hasService returns false for unknown service":
    let manager = ServiceRoutingTableManager.new()
    check not manager.hasService(testKey(0x01))

  asyncTest "count reflects number of tracked services":
    let manager = ServiceRoutingTableManager.new()
    let mainRt = RoutingTable.new(testKey(0x00))

    discard await manager.addService(
      testKey(0x01), mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    discard await manager.addService(
      testKey(0x02), mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )
    discard await manager.addService(
      testKey(0x03), mainRt, DefaultReplication, DefaultMaxBuckets, Both
    )

    check (await manager.count()) == 3

  asyncTest "serviceIds returns all service IDs":
    let manager = ServiceRoutingTableManager.new()
    let mainRt = RoutingTable.new(testKey(0x00))
    let ids = @[testKey(0x01), testKey(0x02), testKey(0x03)]

    for id in ids:
      discard await manager.addService(
        id, mainRt, DefaultReplication, DefaultMaxBuckets, Interest
      )

    let returned = await manager.serviceIds()
    check returned.len == ids.len
    for id in ids:
      check id in returned

  asyncTest "clear removes all service tables":
    let manager = ServiceRoutingTableManager.new()
    let mainRt = RoutingTable.new(testKey(0x00))

    discard await manager.addService(
      testKey(0x01), mainRt, DefaultReplication, DefaultMaxBuckets, Interest
    )
    discard await manager.addService(
      testKey(0x02), mainRt, DefaultReplication, DefaultMaxBuckets, Provided
    )

    await manager.clear()

    check:
      (await manager.count()) == 0
      not manager.hasService(testKey(0x01))
      not manager.hasService(testKey(0x02))

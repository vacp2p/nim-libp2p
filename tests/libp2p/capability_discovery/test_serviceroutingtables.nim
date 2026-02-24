# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import std/[sequtils]
import ../../../libp2p/protocols/capability_discovery/[types, serviceroutingtables]
import ../../../libp2p/protocols/kademlia/[routingtable, types]
import ../../tools/unittest

suite "ServiceRoutingTableManager":
  test "new manager starts empty":
    let m = ServiceRoutingTableManager.new()
    check m.count() == 0
    check m.serviceIds().len == 0

  test "missing service: hasService false, getTable none":
    let m = ServiceRoutingTableManager.new()
    let sid = hashServiceId("ghost")
    check not m.hasService(sid)
    check m.getTable(sid).isNone()

  test "addService registers service":
    let m = ServiceRoutingTableManager.new()
    let sid = hashServiceId("svc-a")
    m.addService(sid, emptyMain(sid), replication = 3, bucketsCount = 16)
    check m.count() == 1
    check m.hasService(sid)
    check m.getTable(sid).isSome()

  test "addService is idempotent":
    let m = ServiceRoutingTableManager.new()
    let sid = hashServiceId("svc-a")
    m.addService(sid, emptyMain(sid), replication = 3, bucketsCount = 16)
    m.addService(sid, emptyMain(sid), replication = 3, bucketsCount = 16)
    check m.count() == 1

  test "multiple services tracked independently":
    let m = ServiceRoutingTableManager.new()
    let s1 = hashServiceId("svc-a")
    let s2 = hashServiceId("svc-b")
    m.addService(s1, emptyMain(s1), replication = 3, bucketsCount = 16)
    m.addService(s2, emptyMain(s2), replication = 3, bucketsCount = 16)
    let ids = m.serviceIds()
    check ids.len == 2
    check s1 in ids
    check s2 in ids

  test "removeService removes table":
    let m = ServiceRoutingTableManager.new()
    let sid = hashServiceId("svc-a")
    m.addService(sid, emptyMain(sid), replication = 3, bucketsCount = 16)
    m.removeService(sid)
    check m.count() == 0
    check not m.hasService(sid)
    check m.getTable(sid).isNone()

  test "removeService on missing service is a no-op":
    let m = ServiceRoutingTableManager.new()
    let sid = hashServiceId("never-added")
    m.removeService(sid) # must not crash
    check m.count() == 0

  test "clear removes all tables":
    let m = ServiceRoutingTableManager.new()
    for i in 0 ..< 5:
      let sid = hashServiceId("svc-" & $i)
      m.addService(sid, emptyMain(sid), replication = 3, bucketsCount = 16)
    m.clear()
    check m.count() == 0
    check m.serviceIds().len == 0

  test "addService after clear works":
    let m = ServiceRoutingTableManager.new()
    let sid = hashServiceId("svc-a")
    m.addService(sid, emptyMain(sid), replication = 3, bucketsCount = 16)
    m.clear()
    m.addService(sid, emptyMain(sid), replication = 3, bucketsCount = 16)
    check m.count() == 1

  test "insertPeer into existing service increments peer count":
    let m = ServiceRoutingTableManager.new()
    let sid = hashServiceId("svc-a")
    m.addService(sid, emptyMain(sid), replication = 3, bucketsCount = 16)
    let before = m.getTable(sid).value().peersCount()
    m.insertPeer(sid, mkKey(0xAA))
    check m.getTable(sid).value().peersCount() == before + 1

  test "insertPeer on missing service is a no-op":
    let m = ServiceRoutingTableManager.new()
    m.insertPeer(hashServiceId("ghost"), mkKey(0x01)) # must not crash
    check m.count() == 0

  test "insertPeer after removeService is a no-op":
    let m = ServiceRoutingTableManager.new()
    let sid = hashServiceId("svc-a")
    m.addService(sid, emptyMain(sid), replication = 3, bucketsCount = 16)
    m.removeService(sid)
    m.insertPeer(sid, mkKey(0x42))   # must not crash or resurrect table
    check m.count() == 0
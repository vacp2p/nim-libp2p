{.used.}
from std/times import now, utc
import chronicles
import chronos
import unittest2
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia/[kademlia, routingtable, keys]
import ../utils/async_tests
import ./utils.nim
import ../helpers

suite "KadDHT - GetVal":
  teardown:
    checkTrackers()

  asyncTest "Get from peer":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad2.findNode(kad1.rtable.selfId)

    let
      key = kad1.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad1.dataTable.insert(key, value, $times.now().utc)

    check:
      containsData(kad1, key, value)
      containsNoData(kad2, key)

    discard await kad2.getValue(key)

    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)

  asyncTest "Get value that is locally present":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad2.findNode(kad1.rtable.selfId)

    let
      key = kad1.rtable.selfId
      value = @[1.byte, 2, 3, 4, 5]

    kad1.dataTable.insert(key, value, $times.now().utc)
    kad2.dataTable.insert(key, value, $times.now().utc)

    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)

    discard await kad2.getValue(key)

    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)

  asyncTest "Divergent getVal responses from peers":
    var (switch1, kad1) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch2, kad2) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch3, kad3) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch4, kad4) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())
    var (switch5, kad5) =
      setupKadSwitch(DefaultEntryValidator(), DefaultEntrySelector())

    defer:
      await allFutures(
        switch1.stop(), switch2.stop(), switch3.stop(), switch4.stop(), switch5.stop()
      )

    await kad1.bootstrap(
      @[switch1.peerInfo, switch3.peerInfo, switch4.peerInfo, switch5.peerInfo]
    )

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad1.findNode(kad3.rtable.selfId)
    discard await kad1.findNode(kad4.rtable.selfId)
    discard await kad1.findNode(kad5.rtable.selfId)

    let
      key = kad4.rtable.selfId
      bestValue = @[1.byte, 2, 3, 4, 5]
      worstValue = @[1.byte, 2, 3, 4, 6]

    kad2.dataTable.insert(key, bestValue, $times.now().utc)
    kad3.dataTable.insert(key, worstValue, $times.now().utc)
    kad4.dataTable.insert(key, bestValue, $times.now().utc)
    kad5.dataTable.insert(key, bestValue, $times.now().utc)

    check:
      containsNoData(kad1, key)
      containsData(kad2, key, bestValue)
      containsData(kad3, key, worstValue)
      containsData(kad4, key, bestValue)
      containsData(kad5, key, bestValue)

    discard await kad1.getValue(key)

    # now all have bestvalue
    check:
      containsData(kad1, key, bestValue)
      containsData(kad2, key, bestValue)
      containsData(kad3, key, bestValue)
      containsData(kad4, key, bestValue)
      containsData(kad5, key, bestValue)

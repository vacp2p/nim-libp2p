{.used.}
import std/[tables]
from std/times import now, utc
import chronicles
import chronos
import unittest2
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia/[kademlia, routingtable, keys]
import ../utils/async_tests
import ./utils.nim
import ../helpers

proc createSwitch(): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .build()

proc countBucketEntries(buckets: seq[Bucket], key: Key): uint32 =
  var res: uint32 = 0
  for b in buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        res += 1
  return res

template setupKadSwitch(validator: untyped, selector: untyped): untyped =
  let switch = createSwitch()
  let kad = KadDHT.new(switch, validator, selector)
  switch.mount(kad)
  await switch.start()
  (switch, kad)

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
      kad1.dataTable.len == 1
      kad2.dataTable.len == 0

    discard await kad2.getValue(key, timeout = 1.seconds)

    let entered1 = kad1.dataTable[key].value
    let entered2 = kad2.dataTable[key].value

    check:
      kad1.dataTable.len == 1
      kad2.dataTable.len == 1
      entered1 == value
      entered2 == value

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
      kad1.dataTable.len == 1
      kad2.dataTable.len == 1

    discard await kad2.getValue(key, timeout = 1.seconds)

    let entered1 = kad1.dataTable[key].value
    let entered2 = kad2.dataTable[key].value

    check:
      kad1.dataTable.len == 1
      kad2.dataTable.len == 1
      entered1 == value
      entered2 == value

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

    let oldKad3Value = kad3.dataTable[key].value
    check:
      kad1.dataTable.len == 0
      kad2.dataTable.len == 1
      kad3.dataTable.len == 1
      kad4.dataTable.len == 1
      kad5.dataTable.len == 1
      oldKad3Value == worstValue

    discard await kad1.getValue(key, timeout = 1.seconds)

    let acceptedValue = kad1.dataTable[key].value
    let newKad3Value = kad3.dataTable[key].value

    check:
      kad1.dataTable.len == 1
      kad2.dataTable.len == 1
      kad3.dataTable.len == 1
      kad4.dataTable.len == 1
      acceptedValue == bestValue # we chose the best value
      newKad3Value == bestValue # we updated kad3 with best value

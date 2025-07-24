{.used.}
import chronicles
import strformat
# import sequtils
import options
import std/[times]
# import std/enumerate
import chronos
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia
import ../../libp2p/protocols/kademlia/routingtable
import ../../libp2p/protocols/kademlia/keys
import ../../libp2p/protocols/kademlia/dhttypes
import unittest2
import ../utils/async_tests
import ./utils.nim
import std/tables
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

suite "KadDHT - PutVal":
  teardown:
    checkTrackers()
  asyncTest "Simple put":
    let switch1 = createSwitch()
    let switch2 = createSwitch()
    var kad1 = KadDHT.new(switch1, PermissiveValidator(), CandSelector())
    var kad2 = KadDHT.new(switch2, PermissiveValidator(), CandSelector())
    switch1.mount(kad1)
    switch2.mount(kad2)

    await allFutures(switch1.start(), switch2.start())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad2.findNode(kad1.rtable.selfId)

    doAssert(len(kad1.dataTable.entries) == 0)
    doAssert(len(kad2.dataTable.entries) == 0)
    let puttedData = kad1.rtable.selfId.getBytes()
    let entryVal = EntryVal(data: puttedData)
    discard await kad2.putValue(kad1.rtable.selfId, entryVal, some(1))

    let entered1: EntryVal =
      kad1.dataTable.entries[EntryKey(data: kad1.rtable.selfId.getBytes())].value
    let entered2: EntryVal =
      kad2.dataTable.entries[EntryKey(data: kad1.rtable.selfId.getBytes())].value

    var ents = kad1.dataTable.entries
    doAssert(entered1.data == puttedData, fmt"table: {ents}, putted: {puttedData}")
    doAssert(len(kad1.dataTable.entries) == 1)

    ents = kad2.dataTable.entries
    doAssert(entered2.data == puttedData, fmt"table: {ents}, putted: {puttedData}")
    doAssert(len(kad2.dataTable.entries) == 1)

  asyncTest "Change Validator":
    let switch1 = createSwitch()
    let switch2 = createSwitch()
    var kad1 = KadDHT.new(switch1, RestrictiveValidator(), CandSelector())
    var kad2 = KadDHT.new(switch2, RestrictiveValidator(), CandSelector())
    switch1.mount(kad1)
    switch2.mount(kad2)

    await allFutures(switch1.start(), switch2.start())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])
    doAssert(len(kad1.dataTable.entries) == 0)
    let puttedData = kad1.rtable.selfId.getBytes()
    let entryVal = EntryVal(data: puttedData)
    discard await kad2.putValue(kad1.rtable.selfId, entryVal, some(1))
    doAssert(len(kad1.dataTable.entries) == 0, fmt"content: {kad1.dataTable.entries}")
    kad1.setValidator(PermissiveValidator())
    discard await kad2.putValue(kad1.rtable.selfId, entryVal, some(1))

    doAssert(len(kad1.dataTable.entries) == 0, fmt"{kad1.dataTable.entries}")
    kad2.setValidator(PermissiveValidator())
    discard await kad2.putValue(kad1.rtable.selfId, entryVal, some(1))
    doAssert(len(kad1.dataTable.entries) == 1, fmt"{kad1.dataTable.entries}")

  asyncTest "Good Time":
    let switch1 = createSwitch()
    let switch2 = createSwitch()
    var kad1 = KadDHT.new(switch1, PermissiveValidator(), CandSelector())
    var kad2 = KadDHT.new(switch2, PermissiveValidator(), CandSelector())
    switch1.mount(kad1)
    switch2.mount(kad2)
    await allFutures(switch1.start(), switch2.start())
    defer:
      await allFutures(switch1.stop(), switch2.stop())
    await kad2.bootstrap(@[switch1.peerInfo])

    let puttedData = EntryVal(data: kad1.rtable.selfId.getBytes())
    discard await kad2.putValue(kad1.rtable.selfId, puttedData, some(1))

    let time: string =
      kad1.dataTable.entries[EntryKey(data: kad1.rtable.selfId.getBytes())].time.ts

    let now = times.now().utc
    let parsed = time.parse(initTimeFormat("yyyy-MM-dd'T'HH:mm:ss'Z'"), utc())

    # get the diff between the stringified-parsed and the direct "now"
    let elapsed = (now - parsed)
    doAssert(elapsed < times.initDuration(seconds = 2))

  asyncTest "Reselect":
    let switch1 = createSwitch()
    let switch2 = createSwitch()
    var kad1 = KadDHT.new(switch1, PermissiveValidator(), OthersSelector())
    var kad2 = KadDHT.new(switch2, PermissiveValidator(), OthersSelector())
    switch1.mount(kad1)
    switch2.mount(kad2)
    await allFutures(switch1.start(), switch2.start())
    defer:
      await allFutures(switch1.stop(), switch2.stop())
    await kad2.bootstrap(@[switch1.peerInfo])

    let puttedData = EntryVal(data: kad1.rtable.selfId.getBytes())
    let entryKey = EntryKey(data: kad1.rtable.selfId.getBytes())
    discard await kad1.putValue(kad1.rtable.selfId, puttedData, some(1))
    doAssert(len(kad2.dataTable.entries) == 1, fmt"{kad1.dataTable.entries}")
    doAssert(kad2.dataTable.entries[entryKey].value == puttedData)
    discard await kad1.putValue(kad1.rtable.selfId, EntryVal(data: @[]), some(1))
    doAssert(kad2.dataTable.entries[entryKey].value == puttedData)
    kad2.setSelector(CandSelector())
    kad1.setSelector(CandSelector())
    discard await kad1.putValue(kad1.rtable.selfId, EntryVal(data: @[]), some(1))
    doAssert(
      kad2.dataTable.entries[entryKey].value == EntryVal(data: @[]),
      fmt"{kad2.dataTable.entries}",
    )

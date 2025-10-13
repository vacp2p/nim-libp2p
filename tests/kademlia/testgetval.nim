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

suite "KadDHT - GetVal":
  teardown:
    checkTrackers()

  asyncTest "Simple get":
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

  # asyncTest "Good Time":
  #   let switch1 = createSwitch()
  #   let switch2 = createSwitch()
  #   var kad1 = KadDHT.new(switch1, PermissiveValidator(), CandSelector())
  #   var kad2 = KadDHT.new(switch2, PermissiveValidator(), CandSelector())
  #   switch1.mount(kad1)
  #   switch2.mount(kad2)
  #   await allFutures(switch1.start(), switch2.start())
  #   defer:
  #     await allFutures(switch1.stop(), switch2.stop())
  #   await kad2.bootstrap(@[switch1.peerInfo])

  #   let entryKey = kad1.rtable.selfId
  #   let entryValue = @[1.byte, 2, 3, 4, 5]
  #   discard await kad2.putValue(entryKey, entryValue, Opt.some(1))

  #   let time: string = kad1.dataTable[entryKey].time

  #   let now = times.now().utc
  #   let parsed = time.parse(initTimeFormat("yyyy-MM-dd'T'HH:mm:ss'Z'"), utc())

  #   # get the diff between the stringified-parsed and the direct "now"
  #   let elapsed = (now - parsed)
  #   doAssert(elapsed < times.initDuration(seconds = 2))

  # asyncTest "Reselect":
  #   let switch1 = createSwitch()
  #   let switch2 = createSwitch()
  #   var kad1 = KadDHT.new(switch1, PermissiveValidator(), OthersSelector())
  #   var kad2 = KadDHT.new(switch2, PermissiveValidator(), OthersSelector())
  #   switch1.mount(kad1)
  #   switch2.mount(kad2)
  #   await allFutures(switch1.start(), switch2.start())
  #   defer:
  #     await allFutures(switch1.stop(), switch2.stop())
  #   await kad2.bootstrap(@[switch1.peerInfo])

  #   let entryKey = kad1.rtable.selfId
  #   let entryValue = @[1.byte, 2, 3, 4, 5]
  #   discard await kad1.putValue(entryKey, entryValue, Opt.some(1))
  #   check:
  #     kad2.dataTable.len == 1
  #     kad2.dataTable[entryKey].value == entryValue
  #   let emptyVal: seq[byte] = @[]
  #   discard await kad1.putValue(entryKey, emptyVal, Opt.some(1))
  #   check kad2.dataTable[entryKey].value == entryValue
  #   kad2.setSelector(CandSelector())
  #   kad1.setSelector(CandSelector())
  #   discard await kad1.putValue(entryKey, emptyVal, Opt.some(1))
  #   check kad2.dataTable[entryKey].value == emptyVal

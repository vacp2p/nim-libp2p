{.used.}
import std/[times, tables]
import chronicles
import chronos
import unittest2
import ../../libp2p/[switch, builders]
import ../../libp2p/protocols/kademlia/[kademlia, routingtable]
import ../utils/async_tests
import ./utils.nim
import ../helpers

suite "KadDHT - PutVal":
  teardown:
    checkTrackers()
  asyncTest "Simple put":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])

    discard await kad1.findNode(kad2.rtable.selfId)
    discard await kad2.findNode(kad1.rtable.selfId)

    check:
      kad1.dataTable.len == 0
      kad2.dataTable.len == 0

    let key = kad1.rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]
    discard await kad2.putValue(key, value)

    check:
      containsData(kad1, key, value)
      containsData(kad2, key, value)

  asyncTest "Change Validator":
    var (switch1, kad1) = setupKadSwitch(RestrictiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(RestrictiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])
    check kad1.dataTable.len == 0
    let key = kad1.rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]

    check:
      (await kad2.putValue(key, value)).isErr()
      kad1.dataTable.len == 0

    kad1.config.validator = PermissiveValidator()
    check:
      (await kad2.putValue(key, value)).isErr()
      kad1.dataTable.len == 0

    kad2.config.validator = PermissiveValidator()
    check:
      (await kad2.putValue(key, value)).isOk()
      containsData(kad1, key, value)
      containsData(kad2, key, value)

  asyncTest "Good Time":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())
    await kad2.bootstrap(@[switch1.peerInfo])

    let key = kad1.rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]
    discard await kad2.putValue(key, value)

    let time: string = kad1.dataTable[key].time

    let now = times.now().utc
    let parsed = time.parse(initTimeFormat("yyyy-MM-dd'T'HH:mm:ss'Z'"), utc())

    # get the diff between the stringified-parsed and the direct "now"
    let elapsed = (now - parsed)
    doAssert(elapsed < times.initDuration(seconds = 2))

  asyncTest "Reselect":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), OthersSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), OthersSelector())
    defer:
      await allFutures(switch1.stop(), switch2.stop())
    await kad2.bootstrap(@[switch1.peerInfo])

    let key = kad1.rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]

    discard await kad1.putValue(key, value)
    check:
      kad2.dataTable.len == 1
      kad2.dataTable[key].value == value

    let emptyVal: seq[byte] = @[]
    discard await kad1.putValue(key, emptyVal)
    check kad2.dataTable[key].value == value

    kad2.config.selector = CandSelector()
    kad1.config.selector = CandSelector()
    discard await kad1.putValue(key, emptyVal)
    check kad2.dataTable[key].value == emptyVal

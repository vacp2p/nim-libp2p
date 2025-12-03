# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[times, tables], chronos, chronicles
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./utils.nim

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

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
    check containsData(kad2, key, value)

    let emptyVal: seq[byte] = @[]
    discard await kad1.putValue(key, emptyVal)
    check containsData(kad2, key, value)

    kad2.config.selector = CandSelector()
    kad1.config.selector = CandSelector()
    discard await kad1.putValue(key, emptyVal)
    check containsData(kad2, key, emptyVal)

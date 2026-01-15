# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[times, tables], chronos
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./utils.nim

suite "KadDHT Put":
  teardown:
    checkTrackers()

  asyncTest "Simple put":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    check:
      kads[0].dataTable.len == 0
      kads[1].dataTable.len == 0

    let key = kads[0].rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]
    discard await kads[1].putValue(key, value)

    check:
      containsData(kads[0], key, value)
      containsData(kads[1], key, value)

  asyncTest "Change Validator":
    let kads = await setupKadSwitches(2, validator = RestrictiveValidator())
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    check kads[0].dataTable.len == 0
    let key = kads[0].rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]

    check:
      (await kads[1].putValue(key, value)).isErr()
      kads[0].dataTable.len == 0

    kads[0].config.validator = PermissiveValidator()
    check:
      (await kads[1].putValue(key, value)).isErr()
      kads[0].dataTable.len == 0

    kads[1].config.validator = PermissiveValidator()
    check:
      (await kads[1].putValue(key, value)).isOk()
      containsData(kads[0], key, value)
      containsData(kads[1], key, value)

  asyncTest "Good Time":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let key = kads[0].rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]
    discard await kads[1].putValue(key, value)

    let time: string = kads[0].dataTable[key].time

    let now = times.now().utc
    let parsed = time.parse(initTimeFormat("yyyy-MM-dd'T'HH:mm:ss'Z'"), utc())

    # get the diff between the stringified-parsed and the direct "now"
    let elapsed = (now - parsed)
    doAssert(elapsed < times.initDuration(seconds = 2))

  asyncTest "Reselect":
    let kads = await setupKadSwitches(2, selector = OthersSelector())
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    let key = kads[0].rtable.selfId
    let value = @[1.byte, 2, 3, 4, 5]

    discard await kads[0].putValue(key, value)
    check containsData(kads[1], key, value)

    let emptyVal: seq[byte] = @[]
    discard await kads[0].putValue(key, emptyVal)
    check containsData(kads[1], key, value)

    kads[1].config.selector = CandSelector()
    kads[0].config.selector = CandSelector()
    discard await kads[0].putValue(key, emptyVal)
    check containsData(kads[1], key, emptyVal)

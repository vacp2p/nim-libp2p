# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../../libp2p/[protocols/kademlia]
import ../../tools/[unittest]

suite "KadDHT Types":
  teardown:
    checkTrackers()

  test "EntryRecord initializer accepts a Value":
    let
      value = Value.init([1.byte, 2, 3])
      time: Timestamp = "2026-01-01T00:00:00Z"
      record = EntryRecord.init(value, Opt.some(time))

    check:
      record.value == value
      record.time == time

  test "Key and Value are not interchangeable":
    check:
      compiles(
        block:
          discard EntryRecord.init(Value.init([1.byte]), Opt.none(Timestamp))
      )

    check:
      not compiles(
        block:
          discard EntryRecord.init(Key.init([1.byte]), Opt.none(Timestamp))
      )

    check:
      not compiles(
        block:
          discard xorDistance(Value.init([1.byte]), Key.init([1.byte]))
      )

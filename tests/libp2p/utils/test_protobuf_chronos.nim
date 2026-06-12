# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import protobuf_serialization
import ../../../libp2p/utils/protobuf_chronos
import ../../tools/[unittest]

type
  DurationMsg {.proto3.} = object
    dur {.fieldNumber: 1, ext.}: Duration

  MomentMsg {.proto3.} = object
    ts {.fieldNumber: 1, ext.}: Moment

  BothMsg {.proto3.} = object
    dur {.fieldNumber: 1, ext.}: Duration
    ts {.fieldNumber: 2, ext.}: Moment

suite "protobuf_chronos":
  test "Duration zero round-trips":
    let enc = Protobuf.encode(DurationMsg(dur: 0.nanoseconds))
    let dec = Protobuf.decode(enc, DurationMsg)
    check dec.dur == 0.nanoseconds

  test "Duration 1 second round-trips":
    let enc = Protobuf.encode(DurationMsg(dur: 1.seconds))
    let dec = Protobuf.decode(enc, DurationMsg)
    check dec.dur == 1.seconds

  test "Duration nanosecond precision preserved":
    let orig = 123_456_789.nanoseconds
    let enc = Protobuf.encode(DurationMsg(dur: orig))
    let dec = Protobuf.decode(enc, DurationMsg)
    check dec.dur == orig

  test "Duration large value round-trips":
    let orig = 24.hours + 30.minutes + 15.seconds + 999.milliseconds
    let enc = Protobuf.encode(DurationMsg(dur: orig))
    let dec = Protobuf.decode(enc, DurationMsg)
    check dec.dur == orig

  test "Duration underlying int64 preserved":
    let ns: int64 = 1_234_567_890_123_456_789
    let enc = Protobuf.encode(DurationMsg(dur: ns.nanoseconds))
    let dec = Protobuf.decode(enc, DurationMsg)
    check dec.dur.nanoseconds == ns

  test "Moment zero (epoch) round-trips":
    let enc = Protobuf.encode(MomentMsg(ts: Moment.init(0, Nanosecond)))
    let dec = Protobuf.decode(enc, MomentMsg)
    check dec.ts == Moment.init(0, Nanosecond)

  test "Moment specific timestamp round-trips":
    let orig = Moment.init(1_000_000, Second)
    let enc = Protobuf.encode(MomentMsg(ts: orig))
    let dec = Protobuf.decode(enc, MomentMsg)
    check dec.ts == orig

  test "Moment nanosecond precision preserved":
    let ns: int64 = 1_700_000_000_123_456_789
    let orig = Moment.init(ns, Nanosecond)
    let enc = Protobuf.encode(MomentMsg(ts: orig))
    let dec = Protobuf.decode(enc, MomentMsg)
    check dec.ts == orig

  test "Moment epochNanoSeconds preserved after round-trip":
    let ns: int64 = 987_654_321_987_654_321
    let orig = Moment.init(ns, Nanosecond)
    let enc = Protobuf.encode(MomentMsg(ts: orig))
    let dec = Protobuf.decode(enc, MomentMsg)
    check dec.ts.epochNanoSeconds() == ns

  test "Duration and Moment coexist in same message":
    let orig =
      BothMsg(dur: 5.seconds + 250.milliseconds, ts: Moment.init(1_000_000, Second))
    let enc = Protobuf.encode(orig)
    let dec = Protobuf.decode(enc, BothMsg)
    check dec.dur == orig.dur
    check dec.ts == orig.ts

  test "multiple Duration re-encodes to same bytes":
    let msg = DurationMsg(dur: 42.seconds)
    check Protobuf.encode(msg) == Protobuf.encode(msg)

  test "multiple Moment re-encodes to same bytes":
    let msg = MomentMsg(ts: Moment.init(42_000, Second))
    check Protobuf.encode(msg) == Protobuf.encode(msg)

  test "distinct Duration values encode to distinct bytes":
    let enc1 = Protobuf.encode(DurationMsg(dur: 1.seconds))
    let enc2 = Protobuf.encode(DurationMsg(dur: 2.seconds))
    check enc1 != enc2

  test "distinct Moment values encode to distinct bytes":
    let enc1 = Protobuf.encode(MomentMsg(ts: Moment.init(1, Second)))
    let enc2 = Protobuf.encode(MomentMsg(ts: Moment.init(2, Second)))
    check enc1 != enc2

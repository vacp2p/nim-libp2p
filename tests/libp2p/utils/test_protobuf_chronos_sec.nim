# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import protobuf_serialization
import ../../../libp2p/utils/protobuf_chronos_sec
import ../../tools/[unittest]

type
  DurationMsg {.proto3.} = object
    dur {.fieldNumber: 1, ext.}: Duration

  MomentMsg {.proto3.} = object
    ts {.fieldNumber: 1, ext.}: Moment

  BothMsg {.proto3.} = object
    dur {.fieldNumber: 1, ext.}: Duration
    ts {.fieldNumber: 2, ext.}: Moment

  DurationSeqMsg {.proto3.} = object
    durs {.fieldNumber: 1, ext.}: seq[Duration]

  MomentSeqMsg {.proto3.} = object
    moments {.fieldNumber: 1, ext.}: seq[Moment]

  BothSeqMsg {.proto3.} = object
    durs {.fieldNumber: 1, ext.}: seq[Duration]
    moments {.fieldNumber: 2, ext.}: seq[Moment]

suite "protobuf_chronos_sec":
  test "Duration zero round-trips":
    let enc = Protobuf.encode(DurationMsg(dur: 0.seconds))
    let dec = Protobuf.decode(enc, DurationMsg)
    check dec.dur == 0.seconds

  test "Duration 1 second round-trips":
    let enc = Protobuf.encode(DurationMsg(dur: 1.seconds))
    let dec = Protobuf.decode(enc, DurationMsg)
    check dec.dur == 1.seconds

  test "Duration large value round-trips":
    let orig = 24.hours + 30.minutes + 15.seconds
    let enc = Protobuf.encode(DurationMsg(dur: orig))
    let dec = Protobuf.decode(enc, DurationMsg)
    check dec.dur == orig

  test "Duration underlying int64 preserved":
    let ns: int64 = 1_234_567_890
    let enc = Protobuf.encode(DurationMsg(dur: ns.seconds))
    let dec = Protobuf.decode(enc, DurationMsg)
    check dec.dur.seconds == ns

  test "Moment specific timestamp round-trips":
    let orig = Moment.init(1_000_000, Second)
    let enc = Protobuf.encode(MomentMsg(ts: orig))
    let dec = Protobuf.decode(enc, MomentMsg)
    check dec.ts == orig

  test "Moment epochSeconds preserved after round-trip":
    let ns: int64 = 987_654_321
    let orig = Moment.init(ns, Second)
    let enc = Protobuf.encode(MomentMsg(ts: orig))
    let dec = Protobuf.decode(enc, MomentMsg)
    check dec.ts.epochSeconds() == ns

  test "Duration and Moment coexist in same message":
    let orig = BothMsg(dur: 5.seconds, ts: Moment.init(1_000_000, Second))
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

  test "seq[Duration] empty round-trips":
    let enc = Protobuf.encode(DurationSeqMsg(durs: @[]))
    let dec = Protobuf.decode(enc, DurationSeqMsg)
    check dec.durs.len == 0

  test "seq[Duration] single element round-trips":
    let enc = Protobuf.encode(DurationSeqMsg(durs: @[5.seconds]))
    let dec = Protobuf.decode(enc, DurationSeqMsg)
    check dec.durs == @[5.seconds]

  test "seq[Duration] multiple elements round-trips":
    let orig = @[1.seconds, 2.minutes, 3.hours]
    let enc = Protobuf.encode(DurationSeqMsg(durs: orig))
    let dec = Protobuf.decode(enc, DurationSeqMsg)
    check dec.durs == orig

  test "seq[Duration] large values round-trip":
    let ns1: int64 = 1_234_567_890
    let ns2: int64 = 9_123_456_789
    let orig = @[ns1.seconds, ns2.seconds]
    let enc = Protobuf.encode(DurationSeqMsg(durs: orig))
    let dec = Protobuf.decode(enc, DurationSeqMsg)
    check dec.durs[0].seconds == ns1
    check dec.durs[1].seconds == ns2

  test "seq[Duration] order preserved":
    let orig = @[3.seconds, 1.seconds, 2.seconds]
    let enc = Protobuf.encode(DurationSeqMsg(durs: orig))
    let dec = Protobuf.decode(enc, DurationSeqMsg)
    check dec.durs[0] == 3.seconds
    check dec.durs[1] == 1.seconds
    check dec.durs[2] == 2.seconds

  test "distinct seq[Duration] encode to distinct bytes":
    let enc1 = Protobuf.encode(DurationSeqMsg(durs: @[1.seconds, 2.seconds]))
    let enc2 = Protobuf.encode(DurationSeqMsg(durs: @[2.seconds, 1.seconds]))
    check enc1 != enc2

  test "seq[Moment] empty round-trips":
    let enc = Protobuf.encode(MomentSeqMsg(moments: @[]))
    let dec = Protobuf.decode(enc, MomentSeqMsg)
    check dec.moments.len == 0

  test "seq[Moment] single element round-trips":
    let orig = @[Moment.init(1_000_000, Second)]
    let enc = Protobuf.encode(MomentSeqMsg(moments: orig))
    let dec = Protobuf.decode(enc, MomentSeqMsg)
    check dec.moments == orig

  test "seq[Moment] multiple elements round-trips":
    let orig = @[Moment.init(1_000_000, Second), Moment.init(1_700_000_000, Second)]
    let enc = Protobuf.encode(MomentSeqMsg(moments: orig))
    let dec = Protobuf.decode(enc, MomentSeqMsg)
    check dec.moments == orig

  test "seq[Moment] second precision preserved":
    let ns1: int64 = 1_700_000_000
    let ns2: int64 = 987_654_321
    let orig = @[Moment.init(ns1, Second), Moment.init(ns2, Second)]
    let enc = Protobuf.encode(MomentSeqMsg(moments: orig))
    let dec = Protobuf.decode(enc, MomentSeqMsg)
    check dec.moments[0].epochSeconds() == ns1
    check dec.moments[1].epochSeconds() == ns2

  test "seq[Moment] order preserved":
    let orig = @[Moment.init(3, Second), Moment.init(1, Second), Moment.init(2, Second)]
    let enc = Protobuf.encode(MomentSeqMsg(moments: orig))
    let dec = Protobuf.decode(enc, MomentSeqMsg)
    check dec.moments[0] == Moment.init(3, Second)
    check dec.moments[1] == Moment.init(1, Second)
    check dec.moments[2] == Moment.init(2, Second)

  test "distinct seq[Moment] encode to distinct bytes":
    let enc1 = Protobuf.encode(
      MomentSeqMsg(moments: @[Moment.init(1, Second), Moment.init(2, Second)])
    )
    let enc2 = Protobuf.encode(
      MomentSeqMsg(moments: @[Moment.init(2, Second), Moment.init(1, Second)])
    )
    check enc1 != enc2

  test "seq[Duration] and seq[Moment] coexist in same message":
    let orig = BothSeqMsg(
      durs: @[1.seconds, 2.minutes],
      moments: @[Moment.init(1_000_000, Second), Moment.init(2_000_000, Second)],
    )
    let enc = Protobuf.encode(orig)
    let dec = Protobuf.decode(enc, BothSeqMsg)
    check dec.durs == orig.durs
    check dec.moments == orig.moments

  test "seq[Duration] re-encodes to same bytes":
    let msg = DurationSeqMsg(durs: @[1.seconds, 2.seconds])
    check Protobuf.encode(msg) == Protobuf.encode(msg)

  test "seq[Moment] re-encodes to same bytes":
    let msg =
      MomentSeqMsg(moments: @[Moment.init(1_000, Second), Moment.init(2_000, Second)])
    check Protobuf.encode(msg) == Protobuf.encode(msg)

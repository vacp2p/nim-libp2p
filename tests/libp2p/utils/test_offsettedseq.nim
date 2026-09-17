# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../../libp2p/utils/offsettedseq
import ../../tools/[unittest]

const StartOffset = 5

func pair(): OffsettedSeq[int] =
  var o = initOffsettedSeq[int](StartOffset)
  o.add(1)
  o.add(2)
  o

suite "OffsettedSeq":
  test "apply reads every element and mutates nothing":
    let o = pair()

    var seen: seq[int]
    o.apply(
      proc(x: int) =
        seen.add(x)
    )

    check seen == @[1, 2]
    check o.s == @[1, 2]
    check o.offset == StartOffset

  test "apply replaces every element with the returned one":
    var o = pair()

    o.apply(
      proc(x: int): int =
        x * 10
    )

    check o.s == @[10, 20]
    check o.offset == StartOffset

  test "apply mutates every element in place":
    var o = pair()

    o.apply(
      proc(x: var int) =
        x.inc()
    )

    check o.s == @[2, 3]
    check o.offset == StartOffset

  test "flushIf drops the leading run and shifts the offset by its length":
    var o = pair()
    o.add(30)
    o.add(3)

    o.flushIf(
      proc(x: int): bool =
        x < 10
    )

    check o.s == @[30, 3]
    check o.offset == StartOffset + 2
    check o.low() == StartOffset + 2
    check o[StartOffset + 2] == 30

  test "flushIf keeps everything when the first element fails":
    var o = initOffsettedSeq[int](StartOffset)
    o.add(30)
    o.add(1)

    o.flushIf(
      proc(x: int): bool =
        x < 10
    )

    check o.s == @[30, 1]
    check o.offset == StartOffset

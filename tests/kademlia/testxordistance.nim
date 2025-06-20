{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import unittest
import chronos
import ../../libp2p/protocols/kademlia/[consts, keys, xordistance]

suite "xor distance":
  test "countLeadingZeroBits works":
    check countLeadingZeroBits(0b00000000'u8) == 8
    check countLeadingZeroBits(0b10000000'u8) == 0
    check countLeadingZeroBits(0b01000000'u8) == 1
    check countLeadingZeroBits(0b00000001'u8) == 7

  test "leadingZeros of xor distance":
    var d: XorDistance
    for i in 0 ..< IdLength:
      d[i] = 0
    check leadingZeros(d) == IdLength * 8

    d[0] = 0b00010000
    check leadingZeros(d) == 3

    d[0] = 0
    d[1] = 0b00100000
    check leadingZeros(d) == 10

  test "xorDistance of identical keys is zero":
    let k = @[
      1'u8, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 0, 1, 2, 3, 4, 5, 6,
      7, 8, 9, 0, 1, 2,
    ].toKey()
    let dist = xorDistance(k, k)
    check:
      leadingZeros(dist) == IdLength * 8
      dist == default(XorDistance)

  test "cmp gives correct order":
    var a: XorDistance
    var b: XorDistance
    a[0] = 0x01
    b[0] = 0x02
    check a < b
    check cmp(a, b) == -1
    check cmp(b, a) == 1
    check cmp(a, a) == 0

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import ../../../libp2p/utils/collections
import ../../tools/[unittest]

suite "take":
  test "shorter than the count returns everything":
    check @[1, 2, 3].take(5) == @[1, 2, 3]
    check newSeq[int]().take(5).len == 0

  test "longer than the count returns the prefix":
    check @[1, 2, 3, 4].take(2) == @[1, 2]
    check @[1, 2, 3, 4].take(4) == @[1, 2, 3, 4]

  test "zero or negative count returns nothing":
    check @[1, 2, 3].take(0).len == 0
    check @[1, 2, 3].take(-1).len == 0

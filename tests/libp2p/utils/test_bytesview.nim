# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import ../../../libp2p/utils/bytesview
import ../../tools/[unittest]

suite "BytesView":
  test "basics":
    var b = BytesView.init(@[byte 1, 2, 3, 4, 5, 6])
    check b.len() == 6
    check @(b.data()) == @([byte 1, 2, 3, 4, 5, 6])
    check @(b.toOpenArray(1, 3)) == @([byte 2, 3])

    b.consume(2)
    check b.len() == 4
    check @(b.data()) == @([byte 3, 4, 5, 6])
    check @(b.toOpenArray(1, 3)) == @([byte 4, 5])

    b.consume(2)
    check b.len() == 2
    check @(b.data()) == @([byte 5, 6])

    b.consume(2)
    check b.len() == 0
    check b.data().len == 0

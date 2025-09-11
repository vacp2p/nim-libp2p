{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import unittest2
import ../libp2p/utils/bytesview

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

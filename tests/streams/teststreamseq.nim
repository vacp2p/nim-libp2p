{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import unittest2
import stew/byteutils
import ../../libp2p/stream/streamseq

suite "StreamSeq":
  test "basics":
    var s: StreamSeq

    check:
      s.data().len == 0

    s.add([byte 0, 1, 2, 3])

    check:
      @(s.data()) == [byte 0, 1, 2, 3]

    s.prepare(10)[0 ..< 3] = [byte 4, 5, 6]

    check:
      @(s.data()) == [byte 0, 1, 2, 3]

    s.commit(3)

    check:
      @(s.data()) == [byte 0, 1, 2, 3, 4, 5, 6]

    s.consume(1)

    check:
      @(s.data()) == [byte 1, 2, 3, 4, 5, 6]

    s.consume(6)

    check:
      @(s.data()) == []

    s.add([])
    check:
      @(s.data()) == []

    var o: seq[byte]

    check:
      0 == s.consumeTo(o)

    s.add([byte 1, 2, 3])

    o.setLen(2)
    o.setLen(s.consumeTo(o))
    check:
      o == [byte 1, 2]

    o.setLen(s.consumeTo(o))

    check:
      o == [byte 3]

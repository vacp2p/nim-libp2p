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
import ../libp2p/utils/zeroqueue

proc toSeq(p: pointer, length: int): seq[byte] =
  let b = cast[ptr UncheckedArray[byte]](p)
  result = newSeq[byte](length)
  for i in 0 ..< length:
    result[i] = b[i]

suite "ZeroQueue":
  test "push-pop":
    var q: ZeroQueue
    check q.len() == 0
    check q.isEmpty()
    check q.pop(1).len == 0

    q.push(@[1'u8, 2, 3])
    q.push(@[4'u8, 5])
    check q.len() == 5
    check not q.isEmpty()

    check q.pop(0).len == 0
    check @[1'u8, 2, 3] == q.pop(3) # pop eactly the size
    check @[4'u8] == q.pop(1) # pop less the pushed
    check @[5'u8] == q.pop(5) # pop more then pushed
    check q.isEmpty()

    # should not push empty seq
    q.push(@[])
    q.push(@[])
    check q.isEmpty()

  test "consumeTo":
    var q: ZeroQueue
    let nbytes = 20
    var pbytes = alloc(nbytes)
    defer:
      dealloc(pbytes)

    # consumeTo should fill up to nbytes (queue is emptied)
    q.clear()
    q.push(@[1'u8, 2, 3])
    q.push(@[4'u8, 5])
    q.push(@[6'u8, 7])
    check q.consumeTo(pbytes, nbytes) == 7
    check q.isEmpty()
    check toSeq(pbytes, 7) == @[1'u8, 2, 3, 4, 5, 6, 7]

    # consumeTo should fill only 1 element, leaving 2 elements in the queue
    q.clear()
    q.push(@[1'u8, 2, 3])
    check q.consumeTo(pbytes, 1) == 1
    check not q.isEmpty()
    check toSeq(pbytes, 1) == @[1'u8]

    # consumeTo should fill only 3 element, leaving 2 elements in the queue
    q.clear()
    q.push(@[4'u8, 5])
    q.push(@[1'u8, 2, 3])
    check q.consumeTo(pbytes, 3) == 3
    check not q.isEmpty()
    check toSeq(pbytes, 3) == @[4'u8, 5, 1]

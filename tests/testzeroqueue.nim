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
  var res = newSeq[byte](length)
  copyMem(res[0].addr, p, length)
  return res

suite "ZeroQueue":
  test "push-pop":
    var q: ZeroQueue
    check q.len() == 0
    check q.isEmpty()
    check q.popChunkSeq(1).len == 0 # pop empty seq when queue is empty

    q.push(@[1'u8, 2, 3])
    q.push(@[4'u8, 5])
    check q.len() == 5
    check not q.isEmpty()

    check q.popChunkSeq(3) == @[1'u8, 2, 3] # pop eactly the size of the chunk
    check q.popChunkSeq(1) == @[4'u8] # pop less then size of the chunk
    check q.popChunkSeq(5) == @[5'u8] # pop more then size of the chunk
    check q.isEmpty()

    # should not push empty seq
    q.push(@[])
    q.push(@[])
    check q.isEmpty()

  test "clear":
    var q: ZeroQueue
    q.push(@[1'u8, 2, 3])
    check not q.isEmpty()
    q.clear()
    check q.isEmpty()
    check q.len() == 0

  test "consumeTo":
    var q: ZeroQueue
    let nbytes = 20
    var pbytes = alloc(nbytes)
    defer:
      dealloc(pbytes)

    # consumeTo: on empty queue
    check q.consumeTo(pbytes, nbytes) == 0

    # consumeTo: emptying whole queue (multiple pushes)
    q.push(@[1'u8, 2, 3])
    q.push(@[4'u8, 5])
    q.push(@[6'u8, 7])
    check q.consumeTo(pbytes, nbytes) == 7
    check toSeq(pbytes, 7) == @[1'u8, 2, 3, 4, 5, 6, 7]
    check q.isEmpty()

    # consumeTo: consuming one chunk of data in two steps
    q.push(@[1'u8, 2, 3])
    # first consume
    check q.consumeTo(pbytes, 1) == 1
    check toSeq(pbytes, 1) == @[1'u8]
    check q.len() == 2
    # second consime
    check q.consumeTo(pbytes, nbytes) == 2
    check toSeq(pbytes, 2) == @[2'u8, 3]
    check q.isEmpty()

    # consumeTo: consuming multiple chunks of data in two steps
    q.clear()
    q.push(@[4'u8, 5])
    q.push(@[1'u8, 2, 3])
    # first consume
    check q.consumeTo(pbytes, 3) == 3
    check toSeq(pbytes, 3) == @[4'u8, 5, 1]
    check q.len() == 2
    # second consume
    check q.consumeTo(pbytes, nbytes) == 2
    check toSeq(pbytes, 2) == @[2'u8, 3]
    check q.isEmpty()

    # consumeTo: parially consume big push multiple times
    q.clear()
    q.push(newSeq[byte](20))
    for i in 1 .. 10:
      check q.consumeTo(pbytes, 2) == 2
    check q.isEmpty()
    check q.consumeTo(pbytes, 2) == 0

    # consumeTo: parially consuming while pushing
    q.push(@[1'u8, 2, 3])
    check q.consumeTo(pbytes, 2) == 2
    check toSeq(pbytes, 2) == @[1'u8, 2]
    q.push(@[1'u8, 2, 3])
    check q.consumeTo(pbytes, 2) == 2
    check toSeq(pbytes, 2) == @[3'u8, 1]
    q.push(@[1'u8, 2, 3])
    check q.consumeTo(pbytes, 2) == 2
    check toSeq(pbytes, 2) == @[2'u8, 3]
    check q.consumeTo(pbytes, 2) == 2
    check toSeq(pbytes, 2) == @[1'u8, 2]
    check q.consumeTo(pbytes, 2) == 1
    check toSeq(pbytes, 1) == @[3'u8]
    check q.isEmpty()

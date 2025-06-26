{.used.}

import unittest2

import ../libp2p/utils/zeroqueue

proc toSeq(p: pointer, length: int): seq[byte] =
  let b = cast[ptr UncheckedArray[byte]](p)
  result = newSeq[byte](length)
  for i in 0 ..< length:
    result[i] = b[i]

suite "ZeroQueue":
  test "All":
    var q: ZeroQueue
    check q.len() == 0
    check q.isEmpty()
    check q.pop(1).len == 0

    q.push(@[10'u8, 20, 30])
    q.push(@[40'u8, 50])
    check q.len() == 5
    check not q.isEmpty()

    check q.pop(0).len == 0
    check @[10'u8, 20, 30] == q.pop(3) # pop eactly the size
    check @[40'u8] == q.pop(1) # pop less the pushed
    check @[50'u8] == q.pop(5) # pop more then pushed
    check q.isEmpty()

    let nbytes = 20
    var pbytes = alloc(nbytes)
    defer:
      dealloc(pbytes)

    # consumeTo should fill up to nbytes (queue is emptied)
    q.clear()
    q.push(@[10'u8, 20, 30])
    q.push(@[40'u8, 50])
    q.push(@[41'u8, 51])
    check q.consumeTo(pbytes, nbytes) == 7
    check q.isEmpty()
    check toSeq(pbytes, 7) == @[10'u8, 20, 30, 40, 50, 41, 51]

    # consumeTo should fill only 1 element, leaving 2 elements in the queue
    q.clear()
    q.push(@[11'u8, 22, 33])
    check q.consumeTo(pbytes, 1) == 1
    check not q.isEmpty()
    check toSeq(pbytes, 1) == @[11'u8]

    # consumeTo should fill only 3 element, leaving 2 elements in the queue
    q.clear()
    q.push(@[44'u8, 55])
    q.push(@[11'u8, 22, 33])
    check q.consumeTo(pbytes, 3) == 3
    check not q.isEmpty()
    check toSeq(pbytes, 3) == @[44'u8, 55, 11]

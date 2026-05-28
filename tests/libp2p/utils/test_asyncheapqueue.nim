# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../../libp2p/utils/asyncheapqueue
import ../../tools/[unittest]

suite "AsyncHeapQueue":
  test "push orders elements as a min-heap":
    let q = newAsyncHeapQueue[int]()
    check q.empty
    check q.len == 0

    q.push(5)
    q.push(1)
    q.push(3)
    q.push(2)
    q.push(4)

    check q.len == 5
    check not q.empty

    var popped: seq[int]
    for _ in 0 ..< 5:
      popped.add(waitFor q.pop())

    check popped == @[1, 2, 3, 4, 5]
    check q.empty

  asyncTest "pop suspends until push wakes it":
    let q = newAsyncHeapQueue[int]()
    let popFut = q.pop()
    check not popFut.finished

    q.push(42)
    let value = await popFut
    check value == 42
    check q.empty

  asyncTest "queued poppers drain in heap order":
    let q = newAsyncHeapQueue[int]()
    let a = q.pop()
    let b = q.pop()
    let c = q.pop()

    # All pushes happen synchronously before any popper resumes, so by the
    # time A wakes up the heap holds {5,10,20,30} and A pops the minimum.
    q.push(10)
    q.push(20)
    q.push(30)
    q.push(5)

    check (await a) == 5
    check (await b) == 10
    check (await c) == 20
    check (await q.pop()) == 30
    check q.empty

  asyncTest "pop can be cancelled without disturbing the heap":
    let q = newAsyncHeapQueue[int]()
    let popFut = q.pop()
    await popFut.cancelAndWait()
    check popFut.cancelled

    q.push(7)
    check (await q.pop()) == 7

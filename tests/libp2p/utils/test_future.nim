# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../../libp2p/utils/future
import ../../tools/[unittest]

suite "Future":
  asyncTest "anyCompleted must complete with first completed future":
    proc fut1() {.async.} =
      await sleepAsync(50.milliseconds)

    proc fut2() {.async.} =
      await sleepAsync(100.milliseconds)

    proc fut3() {.async.} =
      raise newException(CatchableError, "fut3")

    var f1 = fut1()
    var f2 = fut2()
    var f3 = fut3()
    var f = await anyCompleted(@[f1, f2, f3])

    check f == f1

  asyncTest "anyCompleted must fail with empty list":
    expect AllFuturesFailedError:
      discard await anyCompleted(newSeq[Future[void]]())

  asyncTest "anyCompleted must fail if all futures fail":
    proc fut1() {.async.} =
      raise newException(CatchableError, "fut1")

    proc fut2() {.async.} =
      raise newException(CatchableError, "fut2")

    proc fut3() {.async.} =
      raise newException(CatchableError, "fut3")

    var f1 = fut1()
    var f2 = fut2()
    var f3 = fut3()

    expect AllFuturesFailedError:
      discard await anyCompleted(@[f1, f2, f3])

  asyncTest "anyCompleted with timeout":
    proc fut1() {.async.} =
      await sleepAsync(50.milliseconds)

    proc fut2() {.async.} =
      await sleepAsync(100.milliseconds)

    proc fut3() {.async: (raises: [ValueError]).} =
      # fut3 intentionally specifies raised ValueError 
      # so that it's type is of InternalRaisesFuture     
      raise newException(ValueError, "fut3")

    var f1 = fut1()
    var f2 = fut2()
    var f3 = fut3()
    var f = anyCompleted(@[f1, f2, f3])
    if not await f.withTimeout(20.milliseconds):
      f.cancelSoon()

    check f.cancelled()

  asyncTest "cancelSoon cancels pending futures":
    var f1 = newFuture[void]()
    var f2 = newFuture[void]()
    var f3 = newFuture[void]()

    check not f1.finished()
    check not f2.finished()
    check not f3.finished()

    @[f1, f2, f3].cancelSoon()

    check f1.cancelled()
    check f2.cancelled()
    check f3.cancelled()

  asyncTest "cancelSoon is no-op for completed futures":
    var f1 = newFuture[void]()
    var f2 = newFuture[void]()
    f1.complete()
    f2.fail(newException(CatchableError, "error"))

    check f1.completed()
    check f2.failed()

    @[f1, f2].cancelSoon()

    check f1.completed()
    check f2.failed()

  asyncTest "cancelAndWait cancels pending futures":
    var f1 = newFuture[void]()
    var f2 = newFuture[void]()
    var f3 = newFuture[void]()

    check not f1.finished()
    check not f2.finished()
    check not f3.finished()

    await @[f1, f2, f3].cancelAndWait()

    check f1.cancelled()
    check f2.cancelled()
    check f3.cancelled()

  asyncTest "cancelAndWait is no-op for completed futures":
    var f1 = newFuture[void]()
    var f2 = newFuture[void]()
    f1.complete()
    f2.fail(newException(CatchableError, "error"))

    check f1.completed()
    check f2.failed()

    await @[f1, f2].cancelAndWait()

    check f1.completed()
    check f2.failed()

  asyncTest "allFuturesWaitOrTimeout completes all futures within timeout":
    proc work() {.async.} =
      await sleepAsync(10.milliseconds)

    let futs = @[work(), work(), work()]
    await futs.allFuturesWaitOrTimeout(500.milliseconds)
    for f in futs:
      check f.completed()

  asyncTest "allFuturesWaitOrTimeout does not raise on timeout":
    proc slow() {.async.} =
      await sleepAsync(10.seconds)

    let futs = @[slow(), slow()]
    await futs.allFuturesWaitOrTimeout(10.milliseconds)

  asyncTest "allFuturesWaitOrTimeout handles empty sequence":
    await newSeq[Future[void]]().allFuturesWaitOrTimeout(100.milliseconds)

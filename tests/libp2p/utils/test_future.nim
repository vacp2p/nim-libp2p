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
      f.cancel()

    check f.cancelled()

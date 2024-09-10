{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ../helpers
import ../../libp2p/utils/future

suite "Utils Future":
  asyncTest "All Pending Tasks are canceled when returned future is canceled":
    proc longRunningTaskA() {.async.} =
      await sleepAsync(10.seconds)

    proc longRunningTaskB() {.async.} =
      await sleepAsync(10.seconds)

    let
      futureA = longRunningTaskA()
      futureB = longRunningTaskB()

    # Both futures should be canceled when raceCancel is called
    await raceAndCancelPending(@[futureA, futureB]).cancelAndWait()
    check futureA.cancelled
    check futureB.cancelled

  # Test where one task finishes immediately, leading to the cancellation of the pending task
  asyncTest "Cancel Pending Tasks When One Completes":
    proc quickTask() {.async.} =
      return

    proc slowTask() {.async.} =
      await sleepAsync(10.seconds)

    let
      futureQuick = quickTask()
      futureSlow = slowTask()

    # The quick task finishes, so the slow task should be canceled
    await raceAndCancelPending(@[futureQuick, futureSlow])
    check futureQuick.finished
    check futureSlow.cancelled

  asyncTest "raceAndCancelPending with AsyncEvent":
    let asyncEvent = newAsyncEvent()
    let fut1 = asyncEvent.wait()
    let fut2 = newAsyncEvent().wait()
    asyncEvent.fire()
    await raceAndCancelPending(@[fut1, fut2])

    check fut1.finished
    check fut2.cancelled

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos
import ../../../libp2p/utils/[opt, collections, future]
import ../../tools/[unittest]

suite "Utility":
  asyncTest "collectCompleted collects all futures that have finished":
    proc futFinishes(): Future[int] {.async: (raises: [CancelledError]).} =
      await sleepAsync(1.millis)
      return 1

    proc futStalls(): Future[int] {.async: (raises: [CancelledError]).} =
      await sleepAsync(3.seconds)
      return 2

    proc futCancels(): Future[int] {.async: (raises: [CancelledError]).} =
      raise newException(CancelledError, "cancelled")

    let futs = @[futFinishes(), futStalls(), futFinishes(), futCancels()]

    check (await futs.collectCompleted(10.millis)) == @[1, 1]

  test "take":
    let a = @[1, 2, 3, 4]
    check:
      a.take(3) == @[1, 2, 3]
      a.take(5) == @[1, 2, 3, 4]
      a.take(0).len == 0
      a.take(-1).len == 0

suite "withValue and valueOr templates":
  type TestObj = ref object
    x: int

  proc objIncAndOpt(self: TestObj): Opt[TestObj] =
    self.x.inc()
    return Opt.some(self)

  test "withValue calls right branch when Opt is none":
    var counter = 0
    # check Opt withValue with else
    Opt.none(TestObj).withValue(v):
      fail()
    else:
      counter.inc()
    check counter == 1

    # check Opt withValue without else
    Opt.none(TestObj).withValue(v):
      fail()
    check counter == 1

  test "withValue calls right branch when Opt is some":
    var counter = 1
    # check Opt withValue with else
    Opt.some(counter).withValue(v):
      counter.inc(v)
    else:
      fail()

    # check Opt withValue without else
    Opt.some(counter).withValue(v):
      counter.inc(v)

    check counter == 4

  test "withValue calls right branch when Opt is some with proc call":
    var obj = TestObj(x: 0)
    # check Opt withValue with else
    objIncAndOpt(obj).withValue(v):
      v.x.inc()
    else:
      fail()

    # check Opt withValue without else
    objIncAndOpt(obj).withValue(v):
      v.x.inc()

    check obj.x == 4

  test "valueOr calls with and without proc call":
    var obj = Opt.none(TestObj).valueOr:
      TestObj(x: 0)
    check obj.x == 0
    obj = Opt.some(TestObj(x: 2)).valueOr:
      fail()
      return
    check obj.x == 2

    obj = objIncAndOpt(obj).valueOr:
      fail()
      return
    check obj.x == 3

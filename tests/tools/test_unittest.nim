# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos
from std/exitprocs import nil
import ./[unittest]

suite "checkUntilTimeout helpers":
  asyncTest "checkUntilTimeout should pass if the condition is true":
    let a = 2
    let b = 2
    checkUntilTimeout:
      a == b

  asyncTest "checkUntilTimeout should pass if the conditions are true":
    let a = 2
    let b = 2
    checkUntilTimeout:
      a == b
      a == 2
      b == 2

  asyncTest "checkUntilTimeout should pass if condition becomes true after time":
    var a = 1
    let b = 2
    proc makeConditionTrueLater() {.async.} =
      await sleepAsync(50.milliseconds)
      a = 2

    asyncSpawn makeConditionTrueLater()
    checkUntilTimeout:
      a == b

  asyncTest "checkUntilTimeoutCustom should pass when the condition is true":
    let a = 2
    let b = 2
    checkUntilTimeoutCustom(2.seconds, 100.milliseconds):
      a == b

  asyncTest "checkUntilTimeoutCustom should pass when the conditions are true":
    let a = 2
    let b = 2
    checkUntilTimeoutCustom(5.seconds, 100.milliseconds):
      a == b
      a == 2
      b == 2

  asyncTest "checkUntilTimeoutCustom should pass if condition becomes true after time":
    var a = 1
    let b = 2
    proc makeConditionTrueLater() {.async.} =
      await sleepAsync(50.milliseconds)
      a = 2

    asyncSpawn makeConditionTrueLater()
    checkUntilTimeoutCustom(200.milliseconds, 10.milliseconds):
      a == b

suite "checkUntilTimeout helpers - failed":
  var programResultBefore {.threadvar.}: int

  setup:
    programResultBefore = exitProcs.getProgramResult()

  teardown:
    require testStatusIMPL == TestStatus.Failed
    testStatusIMPL = TestStatus.OK
    if programResultBefore == QuitSuccess:
      # if before out test program result was not success, leave it as failed
      exitProcs.setProgramResult(QuitSuccess)

  asyncTest "checkUntilTimeout should timeout if condition is never true":
    checkUntilTimeout:
      false

  asyncTest "checkUntilTimeoutCustom should timeout if condition is never true":
    checkUntilTimeoutCustom(100.milliseconds, 10.milliseconds):
      false

suite "untilTimeout helpers":
  asyncTest "untilTimeout should pass after few attempts":
    let a = 2
    var b = 0

    untilTimeout:
      pre:
        b.inc
      check:
        a == b

    # final check ensures that untilTimeout is actually called
    check:
      a == b

  asyncTest "untilTimeout should pass after few attempts: multi condition":
    let goal1 = 2
    let goal2 = 4
    var val1 = 0
    var val2 = 0

    untilTimeout:
      pre:
        val1.inc
        val2.inc
        val2.inc
      check:
        val1 == goal1
        val2 == goal2

    # final check ensures that untilTimeout is actually called
    check:
      val1 == goal1
      val2 == goal2

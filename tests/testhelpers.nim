{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ./helpers
import unittest2
from std/exitprocs import nil

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
  teardown:
    require testStatusIMPL == TestStatus.Failed
    testStatusIMPL = TestStatus.OK
    exitProcs.setProgramResult(QuitSuccess)

  asyncTest "checkUntilTimeout should timeout if condition is never true":
    checkUntilTimeout:
      false

  asyncTest "checkUntilTimeoutCustom should timeout if condition is never true":
    checkUntilTimeoutCustom(100.milliseconds, 10.milliseconds):
      false

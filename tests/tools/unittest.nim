# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, unittest2, macros
import ./trackers

export checkTrackers # TODO: maybe consider importing it on demand?
export unittest2 except suite

## suite wraps unittest2.suite in a proc to avoid issue with too many global variables
## See https://github.com/nim-lang/Nim/issues/8500
template suite*(name: string, body: untyped): untyped =
  block:
    proc testSuite() =
      unittest2.suite name:
        body

    testSuite()

template asyncTeardown*(body: untyped): untyped =
  teardown:
    waitFor(
      (
        proc() {.async.} =
          body
      )()
    )

template asyncSetup*(body: untyped): untyped =
  setup:
    waitFor(
      (
        proc() {.async.} =
          body
      )()
    )

template asyncTest*(name: string, body: untyped): untyped =
  test name:
    waitFor(
      (
        proc() {.async.} =
          body
      )()
    )

macro checkUntilTimeoutCustom*(
    timeout: Duration, sleepInterval: Duration, code: untyped
): untyped =
  ## Periodically checks a given condition until it is true or a timeout occurs.
  ##
  ## `code`: untyped - A condition expression that should eventually evaluate to true.
  ## `timeout`: Duration - The maximum duration to wait for the condition to be true.
  ##
  ## Examples:
  ##   ```nim
  ##   # Example 1:
  ##   asyncTest "checkUntilTimeoutCustom should pass if the condition is true":
  ##     let a = 2
  ##     let b = 2
  ##     checkUntilTimeoutCustom(2.seconds):
  ##       a == b
  ##
  ##   # Example 2: Multiple conditions
  ##   asyncTest "checkUntilTimeoutCustom should pass if the conditions are true":
  ##     let a = 2
  ##     let b = 2
  ##     checkUntilTimeoutCustom(5.seconds)::
  ##       a == b
  ##       a == 2
  ##       b == 1
  ##   ```
  # Helper proc to recursively build a combined boolean expression
  proc buildAndExpr(n: NimNode): NimNode =
    if n.kind == nnkStmtList and n.len > 0:
      var combinedExpr = n[0] # Start with the first expression
      for i in 1 ..< n.len:
        # Combine the current expression with the next using 'and'
        combinedExpr = newCall("and", combinedExpr, n[i])
      return combinedExpr
    else:
      return n

  # Build the combined expression
  let combinedBoolExpr = buildAndExpr(code)

  result = quote:
    proc checkExpiringInternal(): Future[void] {.gensym, async.} =
      let start = Moment.now()
      while true:
        if Moment.now() > (start + `timeout`):
          checkpoint(
            "[TIMEOUT] Timeout was reached and the conditions were not true. Check if the code is working as " &
              "expected or consider increasing the timeout param."
          )
          check `code`
          return
        else:
          if `combinedBoolExpr`:
            return
          else:
            await sleepAsync(`sleepInterval`)

    await checkExpiringInternal()

macro checkUntilTimeout*(code: untyped): untyped =
  ## Same as `checkUntilTimeoutCustom` but with a default timeout of 30s with 50ms interval.
  ##
  ## Examples:
  ##   ```nim
  ##   # Example 1:
  ##   asyncTest "checkUntilTimeout should pass if the condition is true":
  ##     let a = 2
  ##     let b = 2
  ##     checkUntilTimeout:
  ##       a == b
  ##
  ##   # Example 2: Multiple conditions
  ##   asyncTest "checkUntilTimeout should pass if the conditions are true":
  ##     let a = 2
  ##     let b = 2
  ##     checkUntilTimeout:
  ##       a == b
  ##       a == 2
  ##       b == 1
  ##   ```
  result = quote:
    checkUntilTimeoutCustom(30.seconds, 50.milliseconds, `code`)

template finalCheckTrackers*(): untyped =
  # finalCheckTrackers is a utility used for performing a final tracker check 
  # outside the test suite. It should be called at the very end of a test file 
  # (typically containing a bundle of tests) to ensure that no tests have left 
  # any trackers open.

  unittest2.suite "Final checkTrackers":
    test "test":
      # checkTrackers must be executed within a suite or test; # otherwise, 
      # its output won't appear on stdout.
      checkTrackers()

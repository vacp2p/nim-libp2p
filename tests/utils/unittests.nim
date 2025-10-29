## Use this module instead of unittest2 directly in tests.
## It wraps unittest2.suite in a proc to avoid issue with too many global variables
## See https://github.com/nim-lang/Nim/issues/8500

import unittest2
import chronos

export unittest2 except suite

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

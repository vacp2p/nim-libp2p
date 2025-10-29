import unittest2
import chronos

export unittest2 except suite

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

template suite*(name: string, body: untyped): untyped =
  block:
    proc testSuite() =
      unittest2.suite name:
        body

    testSuite()

import unittest2, chronos

export unittest2, chronos

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

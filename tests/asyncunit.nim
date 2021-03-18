import std/unittest
export unittest

template asyncTeardown*(body: untyped): untyped =
  teardown:
    waitFor((
      proc() {.async, gcsafe.} =
        body
    )())

template asyncSetup*(body: untyped): untyped =
  setup:
    waitFor((
      proc() {.async, gcsafe.} =
        body
    )())

template asyncTest*(name: string, body: untyped): untyped =
  test name:
    waitFor((
      proc() {.async, gcsafe, raises: [Exception].} =
        body
    )())

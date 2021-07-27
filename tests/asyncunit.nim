import unittest2

export unittest2

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
      proc() {.async, gcsafe.} =
        body
    )())

template cancelTest*(name: string, body: untyped): untyped =
  test name:
    proc cancelledTest() {.async, gcsafe.} =
      body
    for i in 0..1000:
      echo "polling ", i ," times"
      let testFuture = cancelledTest()
      for _ in 0..<i:
        if testFuture.finished: break
        poll()
      if testFuture.finished: break #We actually finished the sequence
      echo "cancelling"
      waitFor(testFuture.cancelAndWait())
      #waitFor(sleepAsync(100.milliseconds))
      checkTrackers()

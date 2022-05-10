import random
import chronos

import ../libp2p/utils/heartbeat
import ./helpers

suite "Heartbeat":
  asyncTest "simple heartbeat":
    var i = 0
    proc t() {.async.} =
      heartbeat "shouldn't see this", 10.milliseconds:
        i.inc()
    let hb = t()
    await sleepAsync(100.milliseconds)
    await hb.cancelAndWait()
    check:
      i in 0..11

  asyncTest "change heartbeat period on the fly":
    var i = 0
    proc t() {.async.} =
      var period = 10.milliseconds
      heartbeat "shouldn't see this", period:
        i.inc()
        if i >= 5:
          period = 50.milliseconds
    let hb = t()
    await sleepAsync(500.milliseconds)
    await hb.cancelAndWait()

    # 5x 10 ms heartbeat = 50ms
    # then 10x 50 ms heartbeat = 500ms
    # total 15
    check:
      i in 14..16

  asyncTest "catch up on slow heartbeat":
    var i = 0
    proc t() {.async.} =
      heartbeat "this is normal", 10.milliseconds:
        if i < 3:
          await sleepAsync(50.milliseconds)
        i.inc()

    let hb = t()
    await sleepAsync(300.milliseconds)
    await hb.cancelAndWait()
    # 3x 50ms heartbeat + 10ms interval = 180ms
    # 120ms remaining, / 10ms = 12x
    # total 15
    check:
      i in 14..16

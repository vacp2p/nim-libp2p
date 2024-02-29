{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# MacOs has some nasty jitter when sleeping
# (up to 7 ms), so we skip test there
when not defined(macosx):
  import chronos

  import ../libp2p/utils/heartbeat
  import ./helpers

  suite "Heartbeat":

    asyncTest "simple heartbeat":
      var i = 0
      proc t() {.async.} =
        heartbeat "shouldn't see this", 50.milliseconds:
          i.inc()
      let hb = t()
      await sleepAsync(500.milliseconds)
      await hb.cancelAndWait()
      check:
        i in 9..11

    asyncTest "change heartbeat period on the fly":
      var i = 0
      proc t() {.async.} =
        var period = 30.milliseconds
        heartbeat "shouldn't see this", period:
          i.inc()
          if i >= 4:
            period = 75.milliseconds
      let hb = t()
      await sleepAsync(500.milliseconds)
      await hb.cancelAndWait()

      # 4x 30 ms heartbeat = 120ms
      # (500 ms - 120 ms) / 75ms = 5x 75ms
      # total 9
      check:
        i in 8..10

    asyncTest "catch up on slow heartbeat":
      var i = 0
      proc t() {.async.} =
        heartbeat "this is normal", 30.milliseconds:
          if i < 3:
            await sleepAsync(150.milliseconds)
          i.inc()

      let hb = t()
      await sleepAsync(900.milliseconds)
      await hb.cancelAndWait()
      # 3x (150ms heartbeat + 30ms interval) = 540ms
      # 360ms remaining, / 30ms = 12x
      # total 15
      check:
        i in 14..16

# Nim-Libp2p
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import sequtils
import chronos, chronicles

export chronicles

template heartbeat*(name: string, interval: Duration, body: untyped): untyped =
  var nextHeartbeat = Moment.now()
  while true:
    body

    nextHeartbeat += interval
    let now = Moment.now()
    if nextHeartbeat < now:
      info "Missed heartbeat", heartbeat = name, delay = now - nextHeartbeat
      nextHeartbeat = now + interval
    await sleepAsync(nextHeartbeat - now)

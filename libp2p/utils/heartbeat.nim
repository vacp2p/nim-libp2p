# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import chronos, chronicles

export chronicles

template heartbeat*(name: string, interval: Duration, body: untyped): untyped =
  var nextHeartbeat = Moment.now()
  while true:
    body

    nextHeartbeat += interval
    let now = Moment.now()
    if nextHeartbeat < now:
      let
        delay = now - nextHeartbeat
        itv = interval
      if delay > itv:
        info "Missed multiple heartbeats",
          heartbeat = name, delay = delay, hinterval = itv
      else:
        debug "Missed heartbeat", heartbeat = name, delay = delay, hinterval = itv
      nextHeartbeat = now + itv
    await sleepAsync(nextHeartbeat - now)

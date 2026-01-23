# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.push raises: [].}

import chronos, chronicles

export chronicles

template heartbeat*(
    name: string, interval: Duration, sleepFirst: bool, body: untyped
): untyped =
  if sleepFirst:
    await sleepAsync(interval)

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

template heartbeat*(name: string, interval: Duration, body: untyped): untyped =
  heartbeat(name, interval, sleepFirst = false):
    body

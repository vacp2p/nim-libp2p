# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import chronos, chronicles

export chronicles

template runAfter*(waitTime: Duration, body: untyped): untyped =
  asyncSpawn (
    proc() {.async: (raises: [CancelledError]).} =
      try:
        await sleepAsync(waitTime)
        body
      except CancelledError as e:
        raise e
      except CatchableError as e:
        error "runAfter task failed", msg = e.msg
  )()

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

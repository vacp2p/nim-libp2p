# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import pkg/[chronicles, chronos]

type LogRateLimit* = object
  initialized: bool
  nextAllowed: Moment

proc allowLog*(limit: var LogRateLimit, now = Moment.now()): bool {.raises: [].} =
  ## Bound repeated operational warnings without retaining per-peer state.
  if limit.initialized and now < limit.nextAllowed:
    return false
  limit.initialized = true
  limit.nextAllowed = now + 1.minutes
  true

export LogLevel

template setLogLevel*(level: LogLevel) =
  ## Set the runtime Chronicles log level for all configured sinks.
  ##
  ## This requires compiling with `-d:chronicles_runtime_filtering`.
  when chronicles.runtimeFilteringEnabled:
    chronicles.setLogLevel(level)
  else:
    {.
      error:
        "Run-time Chronicles log filtering is disabled. " &
        "Enable it with '-d:chronicles_runtime_filtering:on'."
    .}

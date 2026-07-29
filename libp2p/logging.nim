# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import pkg/chronicles

export LogLevel

template setLogLevel*(level: LogLevel) =
  ## Set the runtime Chronicles log level for all configured sinks.
  ##
  ## This requires compiling with `-d:chronicles_runtime_filtering`.
  when defined(chronicles_runtime_filtering):
    chronicles.setLogLevel(level)
  else:
    {.error: "Run-time Chronicles log filtering is disabled. " &
      "Enable it with '-d:chronicles_runtime_filtering:on'.".}

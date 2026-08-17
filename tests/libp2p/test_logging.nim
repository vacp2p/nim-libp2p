# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronicles

{.push raises: [].}

# Only a dynamic sink has a writer, and tests/config.nims drops that sink when the build sets its own chronicles defines.
const dynamicSink =
  when compiles(defaultChroniclesStream.outputs[0].writer):
    0
  elif compiles(defaultChroniclesStream.outputs[1].writer):
    1
  else:
    -1

const canCaptureLogs = dynamicSink >= 0 and chronicles.runtimeFilteringEnabled

when canCaptureLogs:
  import std/strutils
  import ../../libp2p/logging as libp2p_logging
  import ../tools/unittest

  # The writer stays installed for the whole test binary, so only this test's records may count.
  const logMarker = "test_logging:"

  var
    deliveredDebug {.threadvar.}: int
    deliveredInfo {.threadvar.}: int

  let captureLog = proc(logLevel: LogLevel, msg: LogOutputStr) {.gcsafe, raises: [].} =
    if logMarker notin msg:
      return
    case logLevel
    of DEBUG:
      inc deliveredDebug
    of INFO:
      inc deliveredInfo
    else:
      discard

  defaultChroniclesStream.outputs[dynamicSink].writer = captureLog

  suite "Logging":
    teardown:
      libp2p_logging.setLogLevel(chronicles.enabledLogLevel)

    test "setLogLevel changes Chronicles runtime threshold":
      libp2p_logging.setLogLevel(INFO)

      debug logMarker & " debug log should be filtered"
      info logMarker & " info log should be delivered"

      check deliveredDebug == 0
      check deliveredInfo == 1
else:
  {.
    warning:
      "test_logging is not compiled: it needs a dynamic chronicles sink and " &
      "'-d:chronicles_runtime_filtering:on'."
  .}

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/typetraits
import chronicles
import ../../libp2p/logging as libp2p_logging
import ../tools/unittest

{.push raises: [].}

var
  deliveredDebug {.threadvar.}: int
  deliveredInfo {.threadvar.}: int

let captureLog = proc(logLevel: LogLevel, msg: LogOutputStr) {.gcsafe, raises: [].} =
  discard msg
  case logLevel
  of DEBUG:
    inc deliveredDebug
  of INFO:
    inc deliveredInfo
  else:
    discard

when defaultChroniclesStream.outputs.type.arity == 1:
  defaultChroniclesStream.outputs[0].writer = captureLog
elif defaultChroniclesStream.outputs.type.arity == 2:
  defaultChroniclesStream.outputs[1].writer = captureLog

suite "Logging":
  test "setLogLevel changes Chronicles runtime threshold":
    libp2p_logging.setLogLevel(INFO)

    debug "debug log should be filtered"
    info "info log should be delivered"

    check deliveredDebug == 0
    check deliveredInfo == 1

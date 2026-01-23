# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

when not defined(nimscript):
  import std/typetraits
  import chronicles

  when defined(chronicles_runtime_filtering):
    setLogLevel(INFO)

  # Suppress dynamic log outputs to prevent "Log message not delivered" warnings
  proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
    discard

  when defaultChroniclesStream.outputs.type.arity == 1:
    defaultChroniclesStream.outputs[0].writer = noOutput
  elif defaultChroniclesStream.outputs.type.arity == 2:
    defaultChroniclesStream.outputs[1].writer = noOutput

{.used.}

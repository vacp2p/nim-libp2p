# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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

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

  when defaultChroniclesStream.outputs.type.arity == 1:
    # Hide the json logs, they're just here to check if we compile
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) =
      discard

    defaultChroniclesStream.outputs[0].writer = noOutput

{.used.}

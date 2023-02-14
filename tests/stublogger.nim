when not defined(nimscript):
  import std/typetraits
  import chronicles

  when defined(chronicles_runtime_filtering):
    setLogLevel(INFO)

  when defaultChroniclesStream.outputs.type.arity == 1:
    # Hide the json logs, they're just here to check if we compile
    proc noOutput(logLevel: LogLevel, msg: LogOutputStr) = discard
    defaultChroniclesStream.outputs[0].writer = noOutput

{.used.}

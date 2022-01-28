# this module will be further extended in PR
# https://github.com/status-im/nim-libp2p/pull/107/

type
  ValidationResult* {.pure.} = enum
    Accept, Reject, Ignore

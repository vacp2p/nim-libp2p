# this module will be further extended in PR
# https://github.com/status-im/nim-libp2p/pull/107/

import ../../utility

type ValidationResult* {.pure, public.} = enum
  Accept
  Reject
  Ignore

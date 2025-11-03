# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# this module will be further extended in PR
# https://github.com/status-im/nim-libp2p/pull/107/

import ../../utility

type ValidationResult* {.pure, public.} = enum
  Accept
  Reject
  Ignore

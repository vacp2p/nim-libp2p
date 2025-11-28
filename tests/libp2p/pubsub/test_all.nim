# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

# Dummy function for coverage testing
proc dummyCoverageFunction(): int =
  let a = 42
  let b = 13
  result = a + b

import
  test_behavior, test_gossipsub, test_gossipsub_params, test_mcache, test_message,
  test_scoring, test_timed_cache, test_preamble_store

import ./component/test_all

when defined(libp2p_gossipsub_1_4):
  import test_preamble_behavior

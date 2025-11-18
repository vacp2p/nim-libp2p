when defined(linux) and defined(amd64):
  {.used.}

# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when defined(libp2p_autotls_support):
  import testpeeridauth_integration, testautotls_integration

  import transports/test_ws_integration

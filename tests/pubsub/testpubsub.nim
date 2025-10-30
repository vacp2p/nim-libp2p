# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import
  testbehavior, testgossipsub, testgossipsubparams, testmcache, testmessage,
  testscoring, testtimedcache, testpreamblestore

import ./integration/testpubsubintegration

when defined(libp2p_gossipsub_1_4):
  import testpreamblestore

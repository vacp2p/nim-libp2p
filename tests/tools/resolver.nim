# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ../../libp2p/nameresolving/mockresolver

export mockresolver

proc default*(T: typedesc[MockResolver]): T =
  let resolver = MockResolver.new()
  resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]
  resolver.ipResponses[("localhost", true)] = @["::1"]
  resolver

# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import ../../libp2p/[multiaddress]

proc countAddressesWithPattern*(addrs: seq[MultiAddress], pattern: MaPattern): int =
  var count: int = 0
  for a in addrs:
    if pattern.match(a):
      count.inc
  count

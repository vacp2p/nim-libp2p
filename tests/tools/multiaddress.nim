# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import ../../libp2p/[multiaddress]

proc countAddressesWithPattern*(addrs: seq[MultiAddress], pattern: MaPattern): int =
  var count: int = 0
  for a in addrs:
    if pattern.match(a):
      count.inc
  count

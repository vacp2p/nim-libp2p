# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import ../../libp2p/[multiaddress]
import ./[unittest, multiaddress]

suite "MultiAddress testing tools":
  test "countAddressesWithPattern":
    let ma =
      @[
        MultiAddress.init("/ip4/127.0.0.1/tcp/48643").get(),
        MultiAddress.init("/ip4/192.168.1.24/tcp/48643").get(),
        MultiAddress.init("/ip6/::1/tcp/55449").get(),
        MultiAddress.init("/ip6/fe80::c96f:38a6:c2af:a22/tcp/55449").get(),
        MultiAddress.init("/ip4/127.0.0.1/tcp/55449").get(),
        MultiAddress.init("/ip4/192.168.1.24/tcp/55449").get(),
      ]
    const
      IPv4Tcp = mapAnd(IP4, mapEq("tcp"))
      IPv6Tcp = mapAnd(IP6, mapEq("tcp"))
      IPv4Ws = mapAnd(IP4, mapEq("ws"))

    check:
      countAddressesWithPattern(ma, IPv4Tcp) == 4
      countAddressesWithPattern(ma, IPv6Tcp) == 2
      countAddressesWithPattern(ma, IPv4Ws) == 0

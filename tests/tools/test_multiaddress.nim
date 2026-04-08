# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import std/net
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

  test "getIp":
    check:
      MultiAddress.init("/ip4/1.2.3.4/tcp/1234").get().getIp() ==
        Opt.some(IpAddress(family: IpAddressFamily.IPv4, address_v4: [1'u8, 2, 3, 4]))
      MultiAddress.init("/ip6/::1/tcp/1234").get().getIp() ==
        Opt.some(
          IpAddress(
            family: IpAddressFamily.IPv6,
            address_v6: [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
          )
        )
      MultiAddress.init("/tcp/1234").get().getIp() == Opt.none(IpAddress)
      MultiAddress.init("/ip4/5.6.7.8/tcp/80/ws").get().getIp() ==
        Opt.some(IpAddress(family: IpAddressFamily.IPv4, address_v4: [5'u8, 6, 7, 8]))

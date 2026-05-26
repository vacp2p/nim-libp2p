# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/net
import ../../libp2p/[multiaddress]
import ./[unittest, multiaddress]

suite "MultiAddress testing tools":
  test "countAddressesWithPattern":
    let ma = @[
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

  test "hasIp":
    proc ma(s: string): MultiAddress =
      MultiAddress.init(s).get()

    check:
      ma("/ip4/1.2.3.4/tcp/1234").hasIp()
      ma("/ip6/::1/tcp/1234").hasIp()
      ma("/ip4/5.6.7.8/tcp/80/ws").hasIp()
      not ma("/tcp/1234").hasIp()
      not ma("/unix/tmp/sock").hasIp()

  test "hasPort":
    proc ma(s: string): MultiAddress =
      MultiAddress.init(s).get()

    check:
      ma("/ip4/1.2.3.4/tcp/1234").hasPort()
      ma("/ip4/1.2.3.4/udp/9000/quic-v1").hasPort()
      ma("/ip6/::1/tcp/1234").hasPort()
      ma("/tcp/1234").hasPort()
      not ma("/ip4/1.2.3.4").hasPort()
      not ma("/unix/tmp/sock").hasPort()

  test "replaceIp":
    proc ma(s: string): MultiAddress =
      MultiAddress.init(s).get()

    let
      ip4 = parseIpAddress("203.0.113.7")
      ip6 = parseIpAddress("2001:db8::1")
    check:
      ma("/ip4/1.2.3.4/tcp/1234").replaceIp(ip4).get == ma("/ip4/203.0.113.7/tcp/1234")
      ma("/ip4/1.2.3.4/tcp/80/ws").replaceIp(ip4).get == ma(
        "/ip4/203.0.113.7/tcp/80/ws"
      )
      ma("/ip4/1.2.3.4/tcp/80/wss").replaceIp(ip4).get ==
        ma("/ip4/203.0.113.7/tcp/80/wss")
      ma("/ip4/1.2.3.4/tcp/80/tls/ws").replaceIp(ip4).get ==
        ma("/ip4/203.0.113.7/tcp/80/tls/ws")
      ma("/ip4/1.2.3.4/udp/9000/quic-v1").replaceIp(ip4).get ==
        ma("/ip4/203.0.113.7/udp/9000/quic-v1")
      ma("/ip6/::1/tcp/1234").replaceIp(ip6).get == ma("/ip6/2001:db8::1/tcp/1234")
      # cross-family swap (IPv6 -> IPv4 and vice versa)
      ma("/ip6/::/tcp/80/ws").replaceIp(ip4).get == ma("/ip4/203.0.113.7/tcp/80/ws")
      ma("/ip4/0.0.0.0/tcp/80").replaceIp(ip6).get == ma("/ip6/2001:db8::1/tcp/80")
      # no IP component -> no-op (returns input unchanged)
      ma("/unix/tmp/sock").replaceIp(ip4).get == ma("/unix/tmp/sock")
      ma("/tcp/1234").replaceIp(ip4).get == ma("/tcp/1234")

  test "replacePort":
    proc ma(s: string): MultiAddress =
      MultiAddress.init(s).get()

    check:
      ma("/ip4/1.2.3.4/tcp/1234").replacePort(Port(5678)).get ==
        ma("/ip4/1.2.3.4/tcp/5678")
      ma("/ip4/1.2.3.4/udp/9000/quic-v1").replacePort(Port(9001)).get ==
        ma("/ip4/1.2.3.4/udp/9001/quic-v1")
      ma("/ip6/::1/tcp/80/ws").replacePort(Port(443)).get == ma("/ip6/::1/tcp/443/ws")
      # no port component -> no-op (returns input unchanged)
      ma("/ip4/1.2.3.4").replacePort(Port(5678)).get == ma("/ip4/1.2.3.4")
      ma("/unix/tmp/sock").replacePort(Port(5678)).get == ma("/unix/tmp/sock")

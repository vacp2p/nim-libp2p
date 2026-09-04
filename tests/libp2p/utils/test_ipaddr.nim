# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, net
import ../../../libp2p/[multiaddress, utils/ipaddr]
import ../../tools/[unittest, multiaddress]

suite "IpAddr Utils":
  teardown:
    checkTrackers()

  test "ipAddrMatches":
    # same ip address
    check ipAddrMatches(ma("/ip4/127.0.0.1/tcp/4041"), @[ma("/ip4/127.0.0.1/tcp/4040")])
    # different ip address
    check not ipAddrMatches(
      ma("/ip4/127.0.0.2/tcp/4041"), @[ma("/ip4/127.0.0.1/tcp/4040")]
    )
    # same ipv6 address
    check ipAddrMatches(
      ma("/ip6/2001:db8::1/tcp/4041"), @[ma("/ip6/2001:db8::1/tcp/4040")]
    )
    # different ipv6 address
    check not ipAddrMatches(
      ma("/ip6/2001:db8::2/tcp/4041"), @[ma("/ip6/2001:db8::1/tcp/4040")]
    )
    # different family
    check not ipAddrMatches(ma("/ip6/::1/tcp/4041"), @[ma("/ip4/127.0.0.1/tcp/4040")])

  test "ipSupport":
    check ipSupport(@[ma("/ip4/127.0.0.1/tcp/4040")]) == (true, false)
    check ipSupport(@[ma("/ip6/::1/tcp/4040")]) == (false, true)
    check ipSupport(@[ma("/ip6/::1/tcp/4040"), ma("/ip4/127.0.0.1/tcp/4040")]) ==
      (true, true)
    check ipSupport(@[ma("/dns4/example.com/tcp/4040")]) == (false, false)

  test "isPrivate, isPublic":
    check isPrivate("192.168.1.100")
    check not isPublic("192.168.1.100")
    check isPrivate("10.0.0.25")
    check not isPublic("10.0.0.25")
    check isPrivate("169.254.12.34")
    check not isPublic("169.254.12.34")
    check isPrivate("172.31.200.8")
    check not isPublic("172.31.200.8")
    check isPrivate("172.16.0.1")
    check not isPublic("172.16.0.1")
    check isPrivate("127.0.0.1")
    check not isPublic("127.0.0.1")
    check not isPrivate("1.1.1.1")
    check isPublic("1.1.1.1")
    check not isPrivate("185.199.108.153")
    check isPublic("185.199.108.153")
    check not isPrivate("8.8.8.8")
    check isPublic("8.8.8.8")
    check not isPrivate("172.15.0.1")
    check isPublic("172.15.0.1")
    check not isPrivate("172.32.0.1")
    check isPublic("172.32.0.1")

  test "isPrivate classifies every IPv6 address as non-private":
    # TODO: nim-libp2p#2710
    # ULA (fc00::/7)
    check not isPrivate("fd00::1")
    check isPublic("fd00::1")
    # link-local (fe80::/10)
    check not isPrivate("fe80::1")
    check isPublic("fe80::1")
    # loopback
    check not isPrivate("::1")
    check isPublic("::1")
    # public IPv6
    check not isPrivate("2001:db8::1")
    check isPublic("2001:db8::1")
    check not isPrivate("2606:4700::1")
    check isPublic("2606:4700::1")

  test "isGlobalIP accepts a public address of either family":
    check isGlobalIP(parseIpAddress("1.1.1.1"))
    check isGlobalIP(parseIpAddress("185.199.108.153"))
    check isGlobalIP(parseIpAddress("2606:4700::1111"))
    check isGlobalIP(parseIpAddress("2a00:1450:4001:800::200e"))

  test "isGlobalIP rejects a non-global address of either family":
    check not isGlobalIP(parseIpAddress("192.168.1.100"))
    check not isGlobalIP(parseIpAddress("10.0.0.25"))
    check not isGlobalIP(parseIpAddress("127.0.0.1"))
    check not isGlobalIP(parseIpAddress("169.254.12.34"))
    # ULA (fc00::/7)
    check not isGlobalIP(parseIpAddress("fd00::1"))
    # link-local (fe80::/10)
    check not isGlobalIP(parseIpAddress("fe80::1"))
    check not isGlobalIP(parseIpAddress("::1"))
    check not isGlobalIP(parseIpAddress("::"))

  test "firstGlobalIP picks the first global address":
    let
      privateV4 = parseIpAddress("192.168.1.100")
      publicV4 = parseIpAddress("1.1.1.1")
      publicV6 = parseIpAddress("2606:4700::1111")
      linkLocalV6 = parseIpAddress("fe80::1")
    check firstGlobalIP(newSeq[IpAddress]()) == Opt.none(IpAddress)
    check firstGlobalIP([privateV4, linkLocalV6]) == Opt.none(IpAddress)
    check firstGlobalIP([privateV4, publicV6]) == Opt.some(publicV6)
    check firstGlobalIP([publicV4, publicV6]) == Opt.some(publicV4)

  test "isIPv4, isIPv6":
    let ipv4 = parseIpAddress("1.2.3.4")
    let ipv6 = parseIpAddress("2001:db8::1")
    check ipv4.isIPv4()
    check not ipv4.isIPv6()
    check ipv6.isIPv6()
    check not ipv6.isIPv4()

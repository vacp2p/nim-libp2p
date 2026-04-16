# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import ../../libp2p/[multiaddress, wire]
import ../tools/[unittest]

suite "Wire":
  test "initTAddress returns ok and correct result for a Unix domain address":
    let ma = MultiAddress.init("/unix/tmp/socket").get()
    let res = initTAddress(ma)
    var address_un: array[108, uint8]
    let unixPath = "/tmp/socket"
    for i in 0 ..< len(unixPath):
      address_un[i] = uint8(unixPath[i])
    let expected = TransportAddress(
      family: AddressFamily.Unix, address_un: address_un, port: Port(1)
    )
    check res.isOk
    check res.get() == expected

  test "initTAddress returns ok and correct result for an IPv4/TCP address":
    let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").get()
    let res = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv4,
      address_v4: [127'u8, 0, 0, 1], # IPv4 address 127.0.0.1
      port: Port(1234),
    )
    check res.isOk
    check res.get() == expected

  test "initTAddress returns ok and correct result for an IPv6/TCP address":
    let ma = MultiAddress.init("/ip6/::1/tcp/1234").get()
    let res = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv6,
      address_v6: [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        # IPv6 address ::1
      port: Port(1234),
    )
    check res.isOk
    check res.get() == expected

  test "initTAddress returns ok and correct result for an IPv4/UDP address":
    let ma = MultiAddress.init("/ip4/127.0.0.1/udp/1234").get()
    let res = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv4,
      address_v4: [127'u8, 0, 0, 1], # IPv4 address 127.0.0.1
      port: Port(1234),
    )
    check res.isOk
    check res.get() == expected

  test "initTAddress returns ok and correct result for an IPv6/UDP address":
    let ma = MultiAddress.init("/ip6/::1/udp/1234").get()
    let res = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv6,
      address_v6: [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        # IPv6 address ::1
      port: Port(1234),
    )
    check res.isOk
    check res.get() == expected

  test "initTAddress returns ok and correct result for an IPv4/TCP/WS address":
    let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234/ws").get()
    let res = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv4,
      address_v4: [127'u8, 0, 0, 1], # IPv4 address 127.0.0.1
      port: Port(1234),
    )
    check res.isOk
    check res.get() == expected

  test "initTAddress returns ok and correct result for an IPv6/TCP/WS address":
    let ma = MultiAddress.init("/ip6/::1/tcp/1234/ws").get()
    let res = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv6,
      address_v6: [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        # IPv6 address ::1
      port: Port(1234),
    )
    check res.isOk
    check res.get() == expected

  test "initTAddress returns ok and correct result for an IPv4/TCP/WSS address":
    let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234/wss").get()
    let res = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv4,
      address_v4: [127'u8, 0, 0, 1], # IPv4 address 127.0.0.1
      port: Port(1234),
    )
    check res.isOk
    check res.get() == expected

  test "initTAddress returns ok and correct result for an IPv6/TCP/WSS address":
    let ma = MultiAddress.init("/ip6/::1/tcp/1234/wss").get()
    let res = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv6,
      address_v6: [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],
        # IPv6 address ::1
      port: Port(1234),
    )
    check res.isOk
    check res.get() == expected

  test "initTAddress returns error for a DNS/TCP/ws address":
    let ma = MultiAddress.init("/dns4/localhost/tcp/1234/ws").get()
    check initTAddress(ma).isErr

  test "initTAddress returns error for a DNS/TCP/wss address":
    let ma = MultiAddress.init("/dns4/localhost/tcp/1234/wss").get()
    check initTAddress(ma).isErr

  test "initTAddress returns error for a DNS/TCP address":
    let ma = MultiAddress.init("/dns4/localhost/tcp/1234").get()
    check initTAddress(ma).isErr

  test "initTAddress returns error for a DNS/UDP address":
    let ma = MultiAddress.init("/dns4/localhost/udp/1234").get()
    check initTAddress(ma).isErr

  test "initTAddress returns error for an Onion3/TCP address":
    let ma = MultiAddress
      .init("/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:1234")
      .get()
    check initTAddress(ma).isErr

  test "initTAddress returns error for a HTTP WebRTCDirect address":
    let ma = MultiAddress.init("/ip4/127.0.0.1/http/p2p-webrtc-direct").get()
    check initTAddress(ma).isErr

  test "initTAddress returns error for a HTTPS WebRTCDirect address":
    let ma = MultiAddress.init("/ip4/127.0.0.1/https/p2p-webrtc-direct").get()
    check initTAddress(ma).isErr

  test "initTAddress returns error for a p2p-circuit address":
    let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234/p2p-circuit").get()
    check initTAddress(ma).isErr

suite "isFilterablePrivateMA":
  proc ma(s: string): MultiAddress =
    MultiAddress.init(s).tryGet()

  test "RFC1918 addresses are filterable":
    check isFilterablePrivateMA(ma("/ip4/10.0.0.1/tcp/4001"))
    check isFilterablePrivateMA(ma("/ip4/172.16.0.1/tcp/4001"))
    check isFilterablePrivateMA(ma("/ip4/172.31.255.255/tcp/4001"))
    check isFilterablePrivateMA(ma("/ip4/192.168.1.5/tcp/4001"))

  test "loopback addresses are filterable":
    check isFilterablePrivateMA(ma("/ip4/127.0.0.1/tcp/4001"))
    check isFilterablePrivateMA(ma("/ip6/::1/tcp/4001"))

  test "link-local addresses are filterable":
    check isFilterablePrivateMA(ma("/ip4/169.254.1.1/tcp/4001"))
    check isFilterablePrivateMA(ma("/ip6/fe80::1/tcp/4001"))

  test "public IPv4 addresses are not filterable":
    check not isFilterablePrivateMA(ma("/ip4/1.1.1.1/tcp/4001"))
    check not isFilterablePrivateMA(ma("/ip4/8.8.8.8/tcp/53"))

  test "DNS addresses are not filterable":
    check not isFilterablePrivateMA(ma("/dns4/example.com/tcp/4001"))
    check not isFilterablePrivateMA(ma("/dns/example.com/tcp/4001"))

  test "circuit relay addresses are not filterable even with private relay IP":
    check not isFilterablePrivateMA(
      ma(
        "/ip4/192.168.1.5/tcp/4001/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/p2p-circuit"
      )
    )
    check not isFilterablePrivateMA(
      ma(
        "/ip4/127.0.0.1/tcp/4001/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC/p2p-circuit"
      )
    )

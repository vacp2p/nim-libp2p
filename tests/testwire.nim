{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ./helpers
import ../libp2p/multiaddress
import ../libp2p/wire

suite "Wire":

  test "initTAddress returns ok and correct result for a Unix domain address":
    let ma = MultiAddress.init("/unix/tmp/socket").get()
    let result = initTAddress(ma)
    var address_un: array[108, uint8]
    let unixPath = "/tmp/socket"
    for i in 0..<len(unixPath):
      address_un[i] = uint8(unixPath[i])
    let expected = TransportAddress(
      family: AddressFamily.Unix,
      address_un: address_un,
      port: Port(1)
    )
    check result.isOk
    check result.get() == expected

  test "initTAddress returns ok and correct result for an IPv4/TCP address":
    let ma = MultiAddress.init("/ip4/127.0.0.1/tcp/1234").get()
    let result = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv4,
      address_v4: [127'u8, 0, 0, 1],  # IPv4 address 127.0.0.1
      port: Port(1234)
    )
    check result.isOk
    check result.get() == expected

  test "initTAddress returns ok and correct result for an IPv6/TCP address":
    let ma = MultiAddress.init("/ip6/::1/tcp/1234").get()
    let result = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv6,
      address_v6: [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],  # IPv6 address ::1
      port: Port(1234)
    )
    check result.isOk
    check result.get() == expected

  test "initTAddress returns ok and correct result for an IPv4/UDP address":
    let ma = MultiAddress.init("/ip4/127.0.0.1/udp/1234").get()
    let result = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv4,
      address_v4: [127'u8, 0, 0, 1],  # IPv4 address 127.0.0.1
      port: Port(1234)
    )
    check result.isOk
    check result.get() == expected

  test "initTAddress returns ok and correct result for an IPv6/UDP address":
    let ma = MultiAddress.init("/ip6/::1/udp/1234").get()
    let result = initTAddress(ma)
    let expected = TransportAddress(
      family: AddressFamily.IPv6,
      address_v6: [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1],  # IPv6 address ::1
      port: Port(1234)
    )
    check result.isOk
    check result.get() == expected

  test "initTAddress returns error for a DNS/TCP address":
    let ma = MultiAddress.init("/dns4/localhost/tcp/1234").get()
    check initTAddress(ma).isErr

  test "initTAddress returns error for a DNS/UDP address":
    let ma = MultiAddress.init("/dns4/localhost/udp/1234").get()
    check initTAddress(ma).isErr

  test "initTAddress returns error for an Onion3/TCP address":
    let ma = MultiAddress.init("/onion3/vww6ybal4bd7szmgncyruucpgfkqahzddi37ktceo3ah7ngmcopnpyyd:1234").get()
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

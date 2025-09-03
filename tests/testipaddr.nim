{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/options
import chronos
import ../libp2p/[utils/ipaddr], ./helpers

proc checkEncodeDecode[T](msg: T) =
  # this would be equivalent of doing the following (e.g. for DialBack)
  # check msg == DialBack.decode(msg.encode()).get()
  check msg == T.decode(msg.encode()).get()

suite "IpAddr Utils":
  teardown:
    checkTrackers()

  test "ipAddrMatches":
    # same ip address
    check ipAddrMatches(
      MultiAddress.init("/ip4/127.0.0.1/tcp/4041").get(),
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get()],
    )
    # different ip address
    check not ipAddrMatches(
      MultiAddress.init("/ip4/127.0.0.2/tcp/4041").get(),
      @[MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get()],
    )

  asyncTest "ipSupport":
    var rng = newRng()
    let ipv4switch = SwitchBuilder
      .new()
      .withRng(rng)
      .withAddresses(@[MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get()])
      .build()
    let ipv6switch = SwitchBuilder
      .new()
      .withRng(rng)
      .withAddresses(@[MultiAddress.init("/ip6/::1/tcp/4040").get()])
      .build()
    let ipv46switch = SwitchBuilder
      .new()
      .withRng(rng)
      .withAddresses(
        @[
          MultiAddress.init("/ip6/::1/tcp/4040").get(),
          MultiAddress.init("/ip4/127.0.0.1/tcp/4040").get(),
        ]
      )
      .build()
    check ipv4switch.ipSupport() == (true, false)
    check ipv6switch.ipSupport() == (false, true)
    check ipv46switch.ipSupport() == (true, true)

  test "isPrivate, isPublic":
    check isPrivate("192.168.1.100")
    check not isPublic("192.168.1.100")
    check isPrivate("10.0.0.25")
    check not isPublic("10.0.0.25")
    check isPrivate("169.254.12.34")
    check not isPublic("169.254.12.34")
    check isPrivate("172.31.200.8")
    check not isPublic("172.31.200.8")
    check not isPrivate("1.1.1.1")
    check isPublic("1.1.1.1")
    check not isPrivate("185.199.108.153")
    check isPublic("185.199.108.153")

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, metrics
import
  ../../../libp2p/
    [builders, switch, services/wildcardresolverservice, multiaddress, multicodec]
import ../../tools/[unittest, crypto]

proc getAddressesMock(
    addrFamily: AddressFamily
): seq[InterfaceAddress] {.gcsafe, raises: [].} =
  try:
    if addrFamily == AddressFamily.IPv4:
      return @[
        InterfaceAddress.init(initTAddress("127.0.0.1:0"), 8),
        InterfaceAddress.init(initTAddress("192.168.1.22:0"), 24),
      ]
    else:
      return @[
        InterfaceAddress.init(initTAddress("::1:0"), 8),
        InterfaceAddress.init(initTAddress("fe80::1:0"), 64),
      ]
  except TransportAddressError as e:
    echo "Error: " & $e.msg
    fail()

proc createSwitch(svc: Service, addrs: seq[MultiAddress]): Switch =
  var switch = SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(addrs, false)
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

  switch.add(svc)

  return switch

suite "WildcardAddressResolverService":
  teardown:
    checkTrackers()

  asyncTest "WildcardAddressResolverService must resolve wildcard addresses and stop doing so when stopped":
    let svc: Service =
      WildcardAddressResolverService.new(networkInterfaceProvider = getAddressesMock)
    let switch = createSwitch(
      svc,
      @[
        MultiAddress.init("/ip4/127.0.0.1/tcp/0/").tryGet(),
        MultiAddress.init("/ip4/0.0.0.0/tcp/0/").tryGet(),
        MultiAddress.init("/ip6/::/tcp/0/").tryGet(),
      ],
    )
    await switch.start()
    let tcpIp4Locahost = switch.peerInfo.addrs[0][multiCodec("tcp")].get
    let tcpIp4Wildcard = switch.peerInfo.addrs[1][multiCodec("tcp")].get
    let tcpIp6 = switch.peerInfo.addrs[3][multiCodec("tcp")].get # tcp port for ip6

    check switch.peerInfo.addrs ==
      @[
        MultiAddress.init("/ip4/127.0.0.1" & $tcpIp4Locahost).get,
        MultiAddress.init("/ip4/127.0.0.1" & $tcpIp4Wildcard).get,
        MultiAddress.init("/ip4/192.168.1.22" & $tcpIp4Wildcard).get,
        MultiAddress.init("/ip6/::1" & $tcpIp6).get,
        MultiAddress.init("/ip6/fe80::1" & $tcpIp6).get,
        # IPv6 dual stack
        MultiAddress.init("/ip4/127.0.0.1" & $tcpIp6).get,
        MultiAddress.init("/ip4/192.168.1.22" & $tcpIp6).get,
      ]
    await switch.stop()
    check switch.peerInfo.addrs ==
      @[
        MultiAddress.init("/ip4/127.0.0.1" & $tcpIp4Locahost).get,
        MultiAddress.init("/ip4/0.0.0.0" & $tcpIp4Wildcard).get,
        MultiAddress.init("/ip6/::" & $tcpIp6).get,
      ]

  test "expandWildcardAddresses expands an IPv4 wildcard to IPv4 interfaces only":
    # an IPv4 wildcard expands only to the IPv4 interfaces
    let expanded = expandWildcardAddresses(
      getAddressesMock, @[MultiAddress.init("/ip4/0.0.0.0/tcp/4001").tryGet()]
    )
    check expanded ==
      @[
        MultiAddress.init("/ip4/127.0.0.1/tcp/4001").tryGet(),
        MultiAddress.init("/ip4/192.168.1.22/tcp/4001").tryGet(),
      ]

  test "expandWildcardAddresses expands an IPv6 wildcard to both IPv6 and IPv4 interfaces":
    # an IPv6 wildcard expands to the IPv6 interfaces
    # and additionally to every IPv4 interface the provider offers
    let expanded = expandWildcardAddresses(
      getAddressesMock, @[MultiAddress.init("/ip6/::/tcp/4001").tryGet()]
    )
    check expanded ==
      @[
        MultiAddress.init("/ip6/::1/tcp/4001").tryGet(),
        MultiAddress.init("/ip6/fe80::1/tcp/4001").tryGet(),
        MultiAddress.init("/ip4/127.0.0.1/tcp/4001").tryGet(),
        MultiAddress.init("/ip4/192.168.1.22/tcp/4001").tryGet(),
      ]

  test "expandWildcardAddresses passes non-wildcard and non-IP addresses through unchanged":
    # a concrete IP is not a wildcard, and a DNS or memory address carries no IP
    # each is returned identical and unduplicated
    let inputs = @[
      MultiAddress.init("/ip4/1.2.3.4/tcp/4001").tryGet(),
      MultiAddress.init("/dns4/example.com/tcp/4001").tryGet(),
      MultiAddress.init("/memorytransport/addr-1").tryGet(),
    ]
    let expanded = expandWildcardAddresses(getAddressesMock, inputs)
    check expanded == inputs

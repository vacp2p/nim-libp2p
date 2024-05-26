{.used.}

# Nim-Libp2p
# Copyright (c) 2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[options, sequtils]
import stew/[byteutils]
import chronos, metrics
import unittest2
import ../libp2p/[builders, switch]
import ../libp2p/services/wildcardresolverservice
import ../libp2p/[multiaddress, multicodec]
import ./helpers
import ../di/di

type NetworkInterfaceProviderMock* = ref object of NetworkInterfaceProvider

method getAddresses(
    networkInterfaceProvider: NetworkInterfaceProviderMock, addrFamily: AddressFamily
): seq[InterfaceAddress] {.gcsafe, raises: [].} =
  echo "getAddressesMock"
  try:
    if addrFamily == AddressFamily.IPv4:
      return
        @[
          InterfaceAddress.init(initTAddress("127.0.0.1:0"), 8),
          InterfaceAddress.init(initTAddress("192.168.1.22:0"), 24),
        ]
    else:
      return
        @[
          InterfaceAddress.init(initTAddress("::1:0"), 8),
          InterfaceAddress.init(initTAddress("fe80::1:0"), 64),
        ]
  except TransportAddressError as e:
    echo "Error: " & $e.msg
    fail()

proc networkInterfaceProviderMock(): NetworkInterfaceProvider =
  NetworkInterfaceProviderMock.new()

proc createSwitch(): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(
    @[
      MultiAddress.init("/ip4/0.0.0.0/tcp/0/").tryGet(),
      MultiAddress.init("/ip6/::/tcp/0/").tryGet(),
    ]
  )
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .withBinding(networkInterfaceProviderMock)
  .build()

suite "WildcardAddressResolverService":
  teardown:
    checkTrackers()

  asyncTest "WildcardAddressResolverService must resolve wildcard addresses and stop doing so when stopped":
    let switch = createSwitch()
    await switch.start()
    let tcpIp4 = switch.peerInfo.addrs[0][multiCodec("tcp")].get # tcp port for ip4
    let tcpIp6 = switch.peerInfo.addrs[2][multiCodec("tcp")].get # tcp port for ip6

    check switch.peerInfo.addrs ==
      @[
        MultiAddress.init("/ip4/127.0.0.1" & $tcpIp4).get,
        MultiAddress.init("/ip4/192.168.1.22" & $tcpIp4).get,
        MultiAddress.init("/ip6/::1" & $tcpIp6).get,
        MultiAddress.init("/ip6/fe80::1" & $tcpIp6).get,
      ]
    await switch.stop()
    check switch.peerInfo.addrs ==
      @[
        MultiAddress.init("/ip4/0.0.0.0" & $tcpIp4).get,
        MultiAddress.init("/ip6/::" & $tcpIp6).get,
      ]

# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos
import ./autonatv2
import ../../libp2p/[builders, peerid, wire, protocols/connectivity/autonatv2/service]
import ../tools/[unittest]

suite "Autonatv2 Interop Tests with Nim nodes":
  asyncTeardown:
    checkTrackers()

  asyncTest "Happy path":
    const peerAddress = "/ip6/::1/tcp/3030"

    let switch = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init(peerAddress).get()])
      .withAutonatV2Server()
      .withAutonatV2(
        serviceConfig =
          AutonatV2ServiceConfig.new(scheduleInterval = Opt.some(1.seconds))
      )
      .withTcpTransport()
      .withYamux()
      .withNoise()
      .build()

    await switch.start()
    defer:
      await switch.stop()

    let peerId = switch.peerInfo.peerId

    const ourAddress = "/ip6/::1/tcp/4040"
    check:
      await autonatInteropTest(ourAddress, peerAddress, peerId)

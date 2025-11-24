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
import ../../../libp2p/[switch, builders]
import ../../../libp2p/protocols/kademlia
import ../../tools/[unittest]
import ./utils.nim

suite "KadDHT Switch Builder":
  teardown:
    checkTrackers()

  asyncTest "Build switch with withKademlia":
    var switch1 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .withKademlia()
      .build()

    var switch2 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .withKademlia(
        bootstrapNodes = @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)]
      )
      .build()

    await allFutures(switch1.start(), switch2.start())
    defer:
      await allFutures(switch1.stop(), switch2.stop())
    check:
      switch1.ms.handlers[1].protos[0] == "/ipfs/kad/1.0.0"

  asyncTest "Use Kad as a client only":
    var switch1 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .withKademlia()
      .build()

    var switch2 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .build()

    let kad2 = KadDHT.new(
      switch2,
      bootstrapNodes = @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
      client = true,
    )

    await allFutures(switch1.start(), switch2.start())
    defer:
      await allFutures(switch1.stop(), switch2.stop())

    check (await kad2.putValue(kad2.rtable.selfId, @[1.byte, 2, 3, 4, 5])).isOk()

# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, stew/byteutils
import ../../libp2p/[switch, builders, peerid, protocols/kademlia, wire]
import ../tools/[unittest]
import ./kadTests

suite "KadDHT Interop Tests":
  # Create and keep a single node running for all tests
  var switch1: Switch
  var kad1: KadDHT
  var peer1Id: PeerId
  var peer1Addr: string

  setup:
    # Create first node once and reuse it across tests
    switch1 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .build()

    kad1 = KadDHT.new(
      switch1, bootstrapNodes = @[], config = KadDHTConfig.new(quorum = 1)
    )

    switch1.mount(kad1)
    await switch1.start()

    # Get the actual address and peer ID of the first node
    peer1Id = switch1.peerInfo.peerId
    peer1Addr = $switch1.peerInfo.addrs[0]

  teardown:
    await switch1.stop()
    checkTrackers()

  asyncTest "kadInteropTest with nim node":
    let ourAddr = "/ip4/127.0.0.1/tcp/0"

    # Test using the kadInteropTest proc (same one used for rust interop)
    let result = await kadInteropTest(peer1Id, peer1Addr, ourAddr)
    check result == true

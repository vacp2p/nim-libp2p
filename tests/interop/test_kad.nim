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

proc kadInteropTest(otherPeerId: PeerId, otherAddr: string, ourAddr: string): Future[bool] {.async.} =
  ## Tests Kademlia DHT interoperability by:
  ## 1. Creating a local switch with Kademlia
  ## 2. Connecting to another peer
  ## 3. Putting a value into the DHT
  ## 4. Retrieving the value to verify it was stored correctly
  var switch = SwitchBuilder
    .new()
    .withRng(newRng())
    .withAddresses(@[MultiAddress.init(ourAddr).tryGet()])
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()

  let kad = KadDHT.new(
    switch,
    bootstrapNodes = @[(otherPeerId, @[MultiAddress.init(otherAddr).get()])],
    config = KadDHTConfig.new(quorum = 1),
  )

  switch.mount(kad)

  await switch.start()
  defer:
    await switch.stop()

  let key: Key = "key".toBytes()
  let value = "value".toBytes()

  let res = await kad.putValue(key, value)
  if res.isErr():
    echo "putValue failed: ", res.error
    return false

  # wait for other peer's kad to store the value
  await sleepAsync(2.seconds)

  # try to get the inserted value from peer
  if (await kad.getValue(key)).get().value != value:
    echo "Get value did not return correct value"
    return false

  return true

suite "KadDHT Interop Tests":
  teardown:
    checkTrackers()

  asyncTest "Success path - two nim nodes":
    # Create first node
    let switch1 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .build()

    let kad1 = KadDHT.new(
      switch1,
      bootstrapNodes = @[],
      config = KadDHTConfig.new(quorum = 1),
    )

    switch1.mount(kad1)
    await switch1.start()

    defer:
      await switch1.stop()

    # Get the actual address and peer ID of the first node
    let peer1Id = switch1.peerInfo.peerId
    let peer1Addr = switch1.peerInfo.addrs[0]

    # Test kadInteropTest with the first node as the "other" peer
    let ourAddr = "/ip4/127.0.0.1/tcp/0"
    let result = await kadInteropTest(peer1Id, $peer1Addr, ourAddr)

    check result == true

  asyncTest "Failure path - invalid peer ID":
    # Create a random peer ID that doesn't correspond to any running node
    let invalidPeerId = PeerId.random().expect("Valid PeerId")
    let nonExistentAddr = "/ip4/127.0.0.1/tcp/9999"
    let ourAddr = "/ip4/127.0.0.1/tcp/0"

    # This should fail because the peer doesn't exist
    # We expect this to return false or timeout
    let switch = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init(ourAddr).tryGet()])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .build()

    let kad = KadDHT.new(
      switch,
      bootstrapNodes = @[(invalidPeerId, @[MultiAddress.init(nonExistentAddr).get()])],
      config = KadDHTConfig.new(quorum = 1),
    )

    switch.mount(kad)
    await switch.start()
    defer:
      await switch.stop()

    let key: Key = "test_key".toBytes()
    let value = "test_value".toBytes()

    # This should fail because there's no valid peer to connect to
    let res = await kad.putValue(key, value)

    # We expect this to fail since the bootstrap node doesn't exist
    check res.isErr()

  asyncTest "Failure path - unreachable address":
    # Create a node with valid configuration
    let switch1 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .build()

    let kad1 = KadDHT.new(
      switch1,
      bootstrapNodes = @[],
      config = KadDHTConfig.new(quorum = 1),
    )

    switch1.mount(kad1)
    await switch1.start()
    defer:
      await switch1.stop()

    # Use the real peer ID but an unreachable address
    let peer1Id = switch1.peerInfo.peerId
    let unreachableAddr = "/ip4/127.0.0.1/tcp/9998" # Different port, won't work

    # Create second node trying to connect to wrong address
    let switch2 = SwitchBuilder
      .new()
      .withRng(newRng())
      .withAddresses(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])
      .withTcpTransport()
      .withMplex()
      .withNoise()
      .build()

    let kad2 = KadDHT.new(
      switch2,
      bootstrapNodes = @[(peer1Id, @[MultiAddress.init(unreachableAddr).get()])],
      config = KadDHTConfig.new(quorum = 1),
    )

    switch2.mount(kad2)
    await switch2.start()
    defer:
      await switch2.stop()

    let key: Key = "test_key".toBytes()
    let value = "test_value".toBytes()

    # This should fail due to unreachable address
    let res = await kad2.putValue(key, value)

    # We expect this to fail
    check res.isErr()

# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, results, options, std/[enumerate, sequtils, tables], stew/byteutils
import
  ../../libp2p/[
    protocols/mix,
    protocols/mix/mix_node,
    protocols/mix/mix_protocol,
    protocols/mix/sphinx,
    protocols/ping,
    peerid,
    multiaddress,
    switch,
    builders,
    crypto/secp,
  ]

import ../tools/[unittest, crypto]

proc createSwitch(
    multiAddr: MultiAddress, libp2pPrivKey: Opt[SkPrivateKey] = Opt.none(SkPrivateKey)
): Switch =
  let privKey = PrivateKey(
    scheme: Secp256k1,
    skkey:
      if libp2pPrivKey.isSome:
        libp2pPrivKey.get()
      else:
        let keyPair = SkKeyPair.random(rng[])
        keyPair.seckey,
  )
  return
    newStandardSwitchBuilder(privKey = Opt.some(privKey), addrs = multiAddr).build()

proc setupSwitches(numNodes: int): seq[Switch] =
  # Initialize mix nodes
  let mixNodes = initializeMixNodes(numNodes).expect("could not initialize nodes")
  var nodes: seq[Switch] = @[]
  for index, mixNode in enumerate(mixNodes):
    let pubInfo =
      mixNodes.getMixPubInfoByIndex(index).expect("could not obtain pub info")

    pubInfo.writeToFile(index).expect("could not write pub info")
    mixNode.writeToFile(index).expect("could not write mix info")

    let switch = createSwitch(mixNode.multiAddr, Opt.some(mixNode.libp2pPrivKey))
    nodes.add(switch)

  return nodes

const NoReplyProtocolCodec = "/test/1.0.0"

type NoReplyProtocol* = ref object of LPProtocol
  receivedMessages*: AsyncQueue[seq[byte]]

proc newNoReplyProtocol*(): NoReplyProtocol =
  let nrProto = NoReplyProtocol()
  nrProto.receivedMessages = newAsyncQueue[seq[byte]]()

  proc handler(conn: Connection, proto: string) {.async: (raises: [CancelledError]).} =
    var buffer: seq[byte]

    try:
      buffer = await conn.readLp(1024)
    except LPStreamError:
      discard

    await conn.close()
    await nrProto.receivedMessages.put(buffer)

  nrProto.handler = handler
  nrProto.codec = NoReplyProtocolCodec
  nrProto

suite "Mix Protocol":
  var switches {.threadvar.}: seq[Switch]

  asyncTeardown:
    await switches.mapIt(it.stop()).allFutures()
    checkTrackers()
    deleteNodeInfoFolder()
    deletePubInfoFolder()

  asyncSetup:
    switches = setupSwitches(10)

  asyncTest "e2e - expect reply, exit != destination":
    var mixProto: seq[MixProtocol] = @[]
    for index, _ in enumerate(switches):
      let proto = MixProtocol.new(index, switches.len, switches[index]).expect(
          "should have initialized mix protocol"
        )
      # We'll fwd requests, so let's register how should the exit node will read responses
      proto.registerDestReadBehavior(PingCodec, readExactly(32))
      mixProto.add(proto)
      switches[index].mount(proto)

    let destNode = createSwitch(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet())
    defer:
      await destNode.stop()

    let pingProto = Ping.new()
    destNode.mount(pingProto)

    # Start all nodes
    await switches.mapIt(it.start()).allFutures()
    await destNode.start()

    let conn = mixProto[0]
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        PingCodec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")

    let response = await pingProto.ping(conn)
    await conn.close()

    check response != 0.seconds

  asyncTest "e2e - expect no reply, exit != destination":
    var mixProto: seq[MixProtocol] = @[]
    for index, _ in enumerate(switches):
      let proto = MixProtocol.new(index, switches.len, switches[index]).expect(
          "should have initialized mix protocol"
        )
      mixProto.add(proto)
      switches[index].mount(proto)

    let destNode = createSwitch(MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet())
    defer:
      await destNode.stop()

    let nrProto = newNoReplyProtocol()
    destNode.mount(nrProto)

    # Start all nodes
    await switches.mapIt(it.start()).allFutures()
    await destNode.start()

    let conn = mixProto[0]
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        NoReplyProtocolCodec,
      )
      .expect("could not build connection")

    let data = @[1.byte, 2, 3, 4, 5]
    await conn.writeLp(data)
    await conn.close()

    check data == await nrProto.receivedMessages.get()

  when defined(libp2p_mix_experimental_exit_is_dest):
    asyncTest "e2e - expect reply, exit == destination":
      var mixProto: seq[MixProtocol] = @[]
      for index, _ in enumerate(switches):
        let proto = MixProtocol.new(index, switches.len, switches[index]).expect(
            "should have initialized mix protocol"
          )
        # We'll fwd requests, so let's register how should the exit node will read responses
        proto.registerDestReadBehavior(PingCodec, readExactly(32))
        mixProto.add(proto)
        switches[index].mount(proto)

      let destNode = switches[^1]
      let pingProto = Ping.new()
      destNode.mount(pingProto)

      # Start all nodes
      await switches.mapIt(it.start()).allFutures()

      let conn = mixProto[0]
        .toConnection(
          MixDestination.exitNode(destNode.peerInfo.peerId),
          PingCodec,
          MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
        )
        .expect("could not build connection")

      let response = await pingProto.ping(conn)
      await conn.close()

      check response != 0.seconds

  asyncTest "length-prefixed protocol - verify readLp fix":
    ## This test verifies the fix for the length prefix bug where responses
    ## from protocols using readLp() were losing their length prefix when
    ## flowing back through the mix network.
    const TestCodec = "/lengthprefix/test/1.0.0"
    const readLen = 1024

    # Test message that will be sent and received
    let testMessage =
      "Privacy for everyone and transparency for people in power is one way to reduce corruption"
    let testPayload = testMessage.toBytes()

    # Future to capture received message at destination
    var receivedAtDest = newFuture[seq[byte]]()

    # Protocol handler at destination that uses writeLp
    type LengthPrefixTestProtocol = ref object of LPProtocol

    proc newLengthPrefixTestProtocol(): LengthPrefixTestProtocol =
      let proto = LengthPrefixTestProtocol()

      proc handle(
          conn: Connection, proto: string
      ) {.async: (raises: [CancelledError]).} =
        try:
          # Read the request with readLp
          let request = await conn.readLp(1024)
          receivedAtDest.complete(request)

          # Send response with writeLp (adds length prefix)
          let response = "Response: " & string.fromBytes(request)
          await conn.writeLp(response.toBytes())
        except CatchableError as e:
          raiseAssert "Unexpected error: " & e.msg

      proto.handler = handle
      proto.codec = TestCodec
      return proto

    var mixProto: seq[MixProtocol] = @[]
    for index, _ in enumerate(switches):
      let proto = MixProtocol.new(index, switches.len, switches[index]).expect(
          "should have initialized mix protocol"
        )
      # Register with readLp behavior - this should preserve length prefix
      proto.registerDestReadBehavior(TestCodec, readLp(readLen))
      mixProto.add(proto)
      switches[index].mount(proto)

    let destNode = switches[^1]
    let testProto = newLengthPrefixTestProtocol()
    destNode.mount(testProto)

    # Start all nodes
    await switches.mapIt(it.start()).allFutures()

    let conn = mixProto[0]
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        TestCodec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")

    # Send request
    await conn.writeLp(testPayload)

    # Verify destination received the message correctly
    check (await receivedAtDest.wait(5.seconds)) == testPayload

    # Read response - this should work correctly with the length prefix fix
    let response = await conn.readLp(readLen)
    await conn.close()

    # Verify the response was read correctly
    let expectedResponse = "Response: " & testMessage
    check string.fromBytes(response) == expectedResponse

  asyncTest "skip and remove nodes with invalid multiaddress from pool":
    # This test validates that nodes with invalid multiaddrs are:
    # 1. Skipped during path construction
    # 2. Removed from pubNodeInfo pool
    # 3. Message still succeeds if enough valid nodes remain

    # Create invalid node with a multiaddr missing transport layer
    let invalidPeerId = PeerId.random().expect("could not generate peerId")
    let invalidMultiAddr =
      MultiAddress.init("/ip4/0.0.0.0").expect("could not initialize invalid multiaddr")

    # Get valid keys from any node's pub info
    let validPubInfo = MixPubInfo.readFromFile(1).expect("could not read pub info")
    let (_, _, validMixPubKey, validLibp2pPubKey) = validPubInfo.get()

    let invalidPubInfo = MixPubInfo.init(
      invalidPeerId, invalidMultiAddr, validMixPubKey, validLibp2pPubKey
    )

    # Setup all mix protocol nodes (needed for forwarding)
    var mixProto: seq[MixProtocol] = @[]
    for index, _ in enumerate(switches):
      let proto = MixProtocol.new(index, switches.len, switches[index]).expect(
          "should have initialized mix protocol"
        )
      mixProto.add(proto)
      switches[index].mount(proto)

    # Calculate how many valid nodes to include in the pool
    # We need at least PathLength nodes after both:
    # 1. Destination node is excluded from path selection
    # 2. Invalid node is removed from pool
    # So we need PathLength + 1 valid nodes minimum (3 + 1 = 4)
    # Since destination (switches[1]) is one of them, we need 4 total valid nodes
    let validNodesCount = min(switches.len - 1, PathLength + 1)
    check switches.len - 1 >= PathLength + 1

    # Now inject invalid node into sender's (node 0) pool
    # Include enough valid nodes so that even after invalid node is removed,
    # we still have sufficient nodes for PathLength = 3
    var nodePool = initTable[PeerId, MixPubInfo]()
    for i in 1 ..< validNodesCount + 1:
      let pubInfo = MixPubInfo.readFromFile(i).expect("could not read pub info")
      nodePool[pubInfo.peerId] = pubInfo

    nodePool[invalidPeerId] = invalidPubInfo
    mixProto[0].setNodePool(nodePool)

    # Verify pool has validNodesCount + 1 invalid node
    check mixProto[0].getNodePoolSize() == validNodesCount + 1

    # Setup destination node
    let nrProto = newNoReplyProtocol()
    switches[1].mount(nrProto)

    # Start all switches - they're needed as intermediate nodes in the mix path
    # even though only sender (0) and destination (1) are doing protocol work
    await switches.mapIt(it.start()).allFutures()

    # Send messages in a loop until invalid node is encountered and removed
    # With validNodesCount + 1 invalid nodes and PathLength=3, we need multiple attempts
    let testPayload = "test message".toBytes()
    var initialPoolSize = mixProto[0].getNodePoolSize()

    # Try up to 20 times to encounter the invalid node
    # Stop if pool size goes below PathLength (can't construct path anymore)
    for attempt in 0 ..< 20:
      if mixProto[0].getNodePoolSize() < PathLength:
        break

      let conn = mixProto[0].toConnection(
        MixDestination.init(switches[1].peerInfo.peerId, switches[1].peerInfo.addrs[0]),
        NoReplyProtocolCodec,
      )

      if conn.isErr:
        # If we can't build connection due to insufficient nodes, break
        break

      await conn.get().writeLp(testPayload)
      discard await nrProto.receivedMessages.get().wait(5.seconds)
      await conn.get().close()

      # Check if invalid node was removed
      if mixProto[0].getNodePoolSize() < initialPoolSize:
        break

    # Verify invalid node was removed from pool (should be 6 valid nodes remaining)
    check mixProto[0].getNodePoolSize() == validNodesCount

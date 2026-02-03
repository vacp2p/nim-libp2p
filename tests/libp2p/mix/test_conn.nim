# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, std/[tables], stew/byteutils
import
  ../../../libp2p/[
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

import ../../tools/[unittest]
import ./utils

const NoReplyProtocolCodec* = "/test/1.0.0"

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

suite "Mix Protocol Component":
  asyncTeardown:
    checkTrackers()
    deleteNodeInfoFolder()
    deletePubInfoFolder()

  asyncTest "expect reply, exit != destination":
    let nodes = await setupMixNodes(
      10, destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32)))
    )
    startNodesAndDeferStop(nodes)

    let (destNode, pingProto) = await setupDestNode(Ping.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0]
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        PingCodec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")

    let response = await pingProto.ping(conn)
    await conn.close()

    check response != 0.seconds

  asyncTest "expect no reply, exit != destination":
    let nodes = await setupMixNodes(10)
    startNodesAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(newNoReplyProtocol())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0]
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
    asyncTest "expect reply, exit == destination":
      let nodes = await setupMixNodes(
        10, destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32)))
      )

      let destNode = nodes[^1]
      let pingProto = Ping.new()
      destNode.switch.mount(pingProto)

      startNodesAndDeferStop(nodes)

      let conn = nodes[0]
        .toConnection(
          MixDestination.exitNode(destNode.switch.peerInfo.peerId),
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

    let nodes = await setupMixNodes(
      10, destReadBehavior = Opt.some((codec: TestCodec, callback: readLp(readLen)))
    )

    let destNode = nodes[^1]
    let testProto = newLengthPrefixTestProtocol()
    destNode.switch.mount(testProto)

    startNodesAndDeferStop(nodes)

    let conn = nodes[0]
      .toConnection(
        MixDestination.init(
          destNode.switch.peerInfo.peerId, destNode.switch.peerInfo.addrs[0]
        ),
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

    # Setup all mix protocol nodes (needed for forwarding)
    let nodes = await setupMixNodes(10)

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

    # Calculate how many valid nodes to include in the pool
    # We need at least PathLength nodes after both:
    # 1. Destination node is excluded from path selection
    # 2. Invalid node is removed from pool
    # So we need PathLength + 1 valid nodes minimum (3 + 1 = 4)
    # Since destination (switches[1]) is one of them, we need 4 total valid nodes
    let validNodesCount = min(nodes.len - 1, PathLength + 1)
    check nodes.len - 1 >= PathLength + 1

    # Now inject invalid node into sender's (node 0) pool
    # Include enough valid nodes so that even after invalid node is removed,
    # we still have sufficient nodes for PathLength = 3
    var nodePool = initTable[PeerId, MixPubInfo]()
    for i in 1 ..< validNodesCount + 1:
      let pubInfo = MixPubInfo.readFromFile(i).expect("could not read pub info")
      nodePool[pubInfo.peerId] = pubInfo

    nodePool[invalidPeerId] = invalidPubInfo
    nodes[0].setNodePool(nodePool)

    # Verify pool has validNodesCount + 1 invalid node
    check nodes[0].getNodePoolSize() == validNodesCount + 1

    # Setup destination node
    let nrProto = newNoReplyProtocol()
    nodes[1].switch.mount(nrProto)

    # Start all switches - they're needed as intermediate nodes in the mix path
    # even though only sender (0) and destination (1) are doing protocol work
    startNodesAndDeferStop(nodes)

    # Send messages in a loop until invalid node is encountered and removed
    # With validNodesCount + 1 invalid nodes and PathLength=3, we need multiple attempts
    let testPayload = "test message".toBytes()
    var initialPoolSize = nodes[0].getNodePoolSize()

    # Try up to 20 times to encounter the invalid node
    # Stop if pool size goes below PathLength (can't construct path anymore)
    for attempt in 0 ..< 20:
      if nodes[0].getNodePoolSize() < PathLength:
        break

      let conn = nodes[0].toConnection(
        MixDestination.init(
          nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs[0]
        ),
        NoReplyProtocolCodec,
      )

      if conn.isErr:
        # If we can't build connection due to insufficient nodes, break
        break

      await conn.get().writeLp(testPayload)
      discard await nrProto.receivedMessages.get().wait(5.seconds)
      await conn.get().close()

      # Check if invalid node was removed
      if nodes[0].getNodePoolSize() < initialPoolSize:
        break

    # Verify invalid node was removed from pool (should be 6 valid nodes remaining)
    check nodes[0].getNodePoolSize() == validNodesCount

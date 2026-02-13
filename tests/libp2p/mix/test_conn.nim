# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, stew/byteutils, sequtils, tables
import
  ../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_protocol,
    protocols/mix/sphinx,
    protocols/ping,
    peerid,
    peerstore,
    multiaddress,
    switch,
    builders,
    crypto/crypto,
    crypto/secp,
  ]
from ../../../libp2p/protocols/mix/fragmentation import DataSize

import ../../tools/[lifecycle, unittest]
import ./utils
import ./mock_mix

suite "Mix Protocol Component":
  asyncTeardown:
    checkTrackers()

  asyncTest "expect reply, exit != destination":
    let nodes = await setupMixNodes(
      10, destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32)))
    )
    startAndDeferStop(nodes)

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
    startAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
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

    # assert anonymity of the sender
    let connPeerId = await nrProto.connPeerIds.get()
    check:
      connPeerId != nodes[0].switch.peerInfo.peerId # not the sender
      connPeerId != destNode.peerInfo.peerId # not the destination itself
      connPeerId in nodes.mapIt(it.switch.peerInfo.peerId)

  asyncTest "path nodes are non-repeating":
    let nodes = await setupMixNodes(10)
    startAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    # Send multiple messages and track which mix node delivered each one
    const numMessages = 20
    var exitNodes: seq[PeerId]

    for i in 0 ..< numMessages:
      let conn = nodes[0]
        .toConnection(
          MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
          NoReplyProtocolCodec,
        )
        .expect("could not build connection")

      await conn.writeLp(@[byte(i)])
      await conn.close()

      discard await nrProto.receivedMessages.get().wait(5.seconds)
      exitNodes.add(await nrProto.connPeerIds.get().wait(5.seconds))

    # Count how many times each node served as exit
    var exitCounts: Table[PeerId, int]
    for peerId in exitNodes:
      exitCounts.mgetOrPut(peerId, 0).inc()

    # With 20 messages and 9 eligible nodes,
    # random selection must produce at least 3 distinct exit nodes.
    # Sender must never be exit and aestination must never be exit.
    # No single node should monopolize the exit role.
    check:
      exitCounts.len >= 3
      nodes[0].switch.peerInfo.peerId notin exitCounts
      destNode.peerInfo.peerId notin exitCounts

  when defined(libp2p_mix_experimental_exit_is_dest):
    asyncTest "expect reply, exit == destination":
      let nodes = await setupMixNodes(
        10, destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32)))
      )

      let destNode = nodes[^1]
      let pingProto = Ping.new()
      destNode.switch.mount(pingProto)

      startAndDeferStop(nodes)

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

    startAndDeferStop(nodes)

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
    # 2. Removed from peerStore MixPubKeyBook
    # 3. Message still succeeds if enough valid nodes remain

    # Setup all mix protocol nodes (needed for forwarding)
    let nodes = await setupMixNodes(10)

    # Create invalid node with a multiaddr missing transport layer
    let invalidPeerId = PeerId.random().expect("could not generate peerId")
    let invalidMultiAddr =
      MultiAddress.init("/ip4/0.0.0.0").expect("could not initialize invalid multiaddr")

    # Get valid keys from any node's pub info (read from pool before clearing)
    let validPubInfo = nodes[0].nodePool.get(nodes[1].switch.peerInfo.peerId).get()
    let (_, _, validMixPubKey, validLibp2pPubKey) = validPubInfo.get()

    let invalidPubInfo = MixPubInfo.init(
      invalidPeerId, invalidMultiAddr, validMixPubKey, validLibp2pPubKey
    )

    # Calculate how many valid nodes to include in the pool
    # We need at least PathLength nodes after both:
    # 1. Destination node is excluded from path selection
    # 2. Invalid node is removed from pool
    # So we need PathLength + 1 valid nodes minimum (3 + 1 = 4)
    # Since destination (nodes[1]) is one of them, we need 4 total valid nodes
    let validNodesCount = min(nodes.len - 1, PathLength + 1)
    check nodes.len - 1 >= PathLength + 1

    # Save pub info from pool before clearing (need it for re-population)
    var savedPubInfos: seq[MixPubInfo]
    for i in 1 ..< validNodesCount + 1:
      savedPubInfos.add(nodes[0].nodePool.get(nodes[i].switch.peerInfo.peerId).get())

    # Now inject invalid node into sender's (node 0) peerStore
    # Include enough valid nodes so that even after invalid node is removed,
    # we still have sufficient nodes for PathLength = 3
    # First clear the existing MixPubKeyBook entries for sender's switch
    let senderPeerStore = nodes[0].switch.peerStore
    for peerId in senderPeerStore[MixPubKeyBook].book.keys.toSeq():
      discard senderPeerStore[MixPubKeyBook].del(peerId)

    # Add valid nodes to peerStore
    for pubInfo in savedPubInfos:
      senderPeerStore[MixPubKeyBook][pubInfo.peerId] = pubInfo.mixPubKey
      senderPeerStore[AddressBook][pubInfo.peerId] = @[pubInfo.multiAddr]
      senderPeerStore[KeyBook][pubInfo.peerId] =
        PublicKey(scheme: Secp256k1, skkey: pubInfo.libp2pPubKey)

    # Add invalid node to peerStore
    senderPeerStore[MixPubKeyBook][invalidPeerId] = invalidPubInfo.mixPubKey
    senderPeerStore[AddressBook][invalidPeerId] = @[invalidPubInfo.multiAddr]
    senderPeerStore[KeyBook][invalidPeerId] =
      PublicKey(scheme: Secp256k1, skkey: invalidPubInfo.libp2pPubKey)

    # Verify pool has validNodesCount + 1 invalid node
    check senderPeerStore[MixPubKeyBook].len == validNodesCount + 1

    # Setup destination node
    let nrProto = NoReplyProtocol.new()
    nodes[1].switch.mount(nrProto)

    # Start all switches - they're needed as intermediate nodes in the mix path
    # even though only sender (0) and destination (1) are doing protocol work
    startAndDeferStop(nodes)

    # Send messages in a loop until invalid node is encountered and removed
    # With validNodesCount + 1 invalid nodes and PathLength=3, we need multiple attempts
    let testPayload = "test message".toBytes()
    var initialPoolSize = senderPeerStore[MixPubKeyBook].len

    # Try up to 20 times to encounter the invalid node
    # Stop if pool size goes below PathLength (can't construct path anymore)
    for attempt in 0 ..< 20:
      if senderPeerStore[MixPubKeyBook].len < PathLength:
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
      if senderPeerStore[MixPubKeyBook].len < initialPoolSize:
        break

    # Verify invalid node was removed from pool (should be 6 valid nodes remaining)
    check senderPeerStore[MixPubKeyBook].len == validNodesCount

  asyncTest "multiple SURBs - reply received when one path unavailable":
    ## 2 SURBs with separate paths.
    ## Stop a node from SURB[0]'s path after forward delivery.
    ## Reply must arrive via SURB[1].
    const TestCodec = "/delayed-response/test/1.0.0"
    const ReadLen = 1024

    let testPayload = "forward message".toBytes()
    let responseData = "reply via surviving SURB".toBytes()

    var received = newFuture[seq[byte]]()
    var proceed = newFuture[void]()

    let destProto = LPProtocol.new()
    destProto.codec = TestCodec
    destProto.handler = proc(
        conn: Connection, proto: string
    ) {.async: (raises: [CancelledError]).} =
      try:
        received.complete(await conn.readLp(ReadLen))
        await proceed
        await conn.writeLp(responseData)
      except CatchableError as e:
        raiseAssert e.msg

    let (nodes, mock) = await setupMixNodesWithMock(
      10, destReadBehavior = Opt.some((codec: TestCodec, callback: readLp(ReadLen)))
    )

    let (destNode, _) = await setupDestNode(destProto)

    # Force separate SURB paths: nodes[2..4] for SURB 0, nodes[5..7] for SURB 1
    mock.surbPeerSets =
      @[
        nodes[2 .. 4].mapIt(it.switch.peerInfo.peerId),
        nodes[5 .. 7].mapIt(it.switch.peerInfo.peerId),
      ]

    await startNodes(nodes)
    defer:
      await stopDestNode(destNode)
      await stopNodes(nodes)

    let conn = mock
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        TestCodec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(2))),
      )
      .expect("could not build connection")

    await conn.writeLp(testPayload)

    check testPayload == await received.wait(10.seconds)

    # Stop a node from SURB[0]'s path
    let nodeToStop =
      nodes.filterIt(it.switch.peerInfo.peerId == mock.actualSurbPeers[0][0])[0]
    await nodeToStop.switch.stop()

    # Signal dest node to send reply — must arrive via SURB[1]
    proceed.complete()

    let response = await conn.readLp(ReadLen).wait(10.seconds)
    await conn.close()

    check response == responseData

  asyncTest "sender receives empty response when destination is unreachable":
    ## Exit node gets DialFailedError, sends empty reply via SURB,
    ## sender receives an empty response from readLp().
    let nodes = await setupMixNodes(
      10, destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32)))
    )

    let (destNode, _) = await setupDestNode(Ping.new())
    let destPeerId = destNode.peerInfo.peerId
    let destAddr = destNode.peerInfo.addrs[0]
    await stopDestNode(destNode)

    startAndDeferStop(nodes)

    let conn = nodes[0]
      .toConnection(
        MixDestination.init(destPeerId, destAddr),
        PingCodec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")
    defer:
      await conn.close()

    await conn.write(@[1.byte, 2, 3, 4, 5])

    let response = await conn.readLp(1024).wait(10.seconds)
    check response.len == 0

  asyncTest "send fails when pool has not enough nodes":
    let nodes = await setupMixNodes(3) # each node's pool = 2 peers (< PathLength)
    startAndDeferStop(nodes)

    let (destNode, _) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0]
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        NoReplyProtocolCodec,
      )
      .expect("could not build connection")
    defer:
      await conn.close()

    expect LPStreamError:
      await conn.writeLp(@[1.byte, 2, 3])

  asyncTest "toConnection rejects expectReply without destReadBehavior":
    let nodes = await setupMixNodes(10) # no destReadBehavior registered
    startAndDeferStop(nodes)

    let (destNode, _) = await setupDestNode(Ping.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0].toConnection(
      MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
      "/test/codec",
      MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
    )

    check:
      conn.isErr
      conn.error == "no destination read behavior for codec"

  asyncTest "read from write-only connection raises error":
    let nodes = await setupMixNodes(10)
    startAndDeferStop(nodes)

    let (destNode, _) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0]
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        NoReplyProtocolCodec, # no expectReply, connection is write-only
      )
      .expect("could not build connection")
    defer:
      await conn.close()

    expect LPStreamError:
      discard await conn.readLp(1024)

  asyncTest "write rejects oversized messages":
    let nodes = await setupMixNodes(10)
    startAndDeferStop(nodes)

    let (destNode, _) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let conn = nodes[0]
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        NoReplyProtocolCodec,
      )
      .expect("could not build connection")
    defer:
      await conn.close()

    expect LPStreamError:
      await conn.write(newSeq[byte](DataSize + 1))

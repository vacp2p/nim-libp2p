# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, stew/byteutils, sequtils, tables
import
  ../../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_protocol,
    protocols/mix/sphinx,
    protocols/mix/delay_strategy,
    protocols/ping,
    peerid,
    peerstore,
    multiaddress,
    switch,
    builders,
    crypto/crypto,
    crypto/secp,
  ]

import ../../../tools/[lifecycle, unittest]
import ../utils
import ../mock_mix

suite "Mix Protocol - Node Failures":
  asyncTeardown:
    checkTrackers()

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
    mock.surbPeerSets = @[
      nodes[2 .. 4].mapIt(it.switch.peerInfo.peerId),
      nodes[5 .. 7].mapIt(it.switch.peerInfo.peerId),
    ]

    await startNodes(nodes)
    defer:
      await stopDestNode(destNode)
      await stopNodes(nodes)

    let conn = mock
      .toConnection(
        destNode.toMixDestination(),
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

    check:
      response == responseData
      mock.receivedPacketCount == 1

  asyncTest "multiple SURBs - both replies received, only one delivered":
    ## 2 SURBs, all paths healthy. Exit sends reply via ALL SURBs.
    ## Both replies arrive at the sender's mix layer,
    ## but only one is delivered to the application.
    let (nodes, mock) = await setupMixNodesWithMock(
      10, destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32)))
    )

    let (destNode, pingProto) = await setupDestNode(Ping.new())

    await startNodes(nodes)
    defer:
      await stopDestNode(destNode)
      await stopNodes(nodes)

    let conn = mock
      .toConnection(
        destNode.toMixDestination(),
        pingProto.codec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(2))),
      )
      .expect("could not build connection")
    defer:
      await conn.close()

    let response = await pingProto.ping(conn)
    check response != 0.seconds

    # Second read: no more replies delivered
    expect LPStreamEOFError:
      var buf: byte
      await conn.readExactly(addr buf, 1)

    # Both SURB replies arrived at the mix layer
    checkUntilTimeout:
      mock.receivedPacketCount == 2

  asyncTest "sender receives empty response when destination is unreachable":
    ## Exit node gets DialFailedError, sends empty reply via SURB,
    ## sender receives an empty response from readLp().
    let nodes = await setupMixNodes(
      10, destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32)))
    )

    let (destNode, pingProto) = await setupDestNode(Ping.new())
    let destPeerId = destNode.peerInfo.peerId
    let destAddr = destNode.peerInfo.addrs[0]
    await stopDestNode(destNode)

    startAndDeferStop(nodes)

    let conn = nodes[0]
      .toConnection(
        MixDestination.init(destPeerId, destAddr),
        pingProto.codec,
        MixParameters(expectReply: Opt.some(true), numSurbs: Opt.some(byte(1))),
      )
      .expect("could not build connection")
    defer:
      await conn.close()

    await conn.write(@[1.byte, 2, 3, 4, 5])

    let response = await conn.readLp(1024).wait(10.seconds)
    check response.len == 0

  asyncTest "forward path node down - hop 2 or exit":
    ## With 4 mix nodes the sender (node 0) has a pool of exactly 3 nodes.
    ## After sending, we identify the first hop, then stop one of the other two nodes.

    ## The high delay ensures intermediaries hold the packet long enough
    ## to stop the target node before it is forwarded.
    let delayStrategy: DelayStrategy = FixedDelayStrategy(delay: 1000)

    let nodes = await setupMixNodes(4, delayStrategy = Opt.some(delayStrategy))
    startAndDeferStop(nodes)

    let (destNode, nrProto) = await setupDestNode(NoReplyProtocol.new())
    defer:
      await stopDestNode(destNode)

    let sender = nodes[0]

    let conn = sender.toConnection(destNode.toMixDestination(), nrProto.codec).expect(
        "could not build connection"
      )
    defer:
      await conn.close()

    await conn.writeLp(@[1.byte, 2, 3])

    # Filter out the first hop
    let nodesToStop =
      nodes[1 ..^ 1].filterIt(not sender.switch.isConnected(it.switch.peerInfo.peerId))

    # Stop hop 2 or exit
    await nodesToStop[0].switch.stop()

    # Destination must never receive the message
    # Wait at least 5s to ensure failure is from the stopped node
    expect AsyncTimeoutError:
      discard await nrProto.receivedMessages.get().wait(5.seconds)

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

      let conn = nodes[0].toConnection(nodes[1].toMixDestination(), nrProto.codec)

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

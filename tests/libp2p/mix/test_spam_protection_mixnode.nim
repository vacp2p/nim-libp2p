# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results, stew/byteutils
import
  ../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_protocol,
    protocols/ping,
    peerid,
    multiaddress,
    switch,
    builders,
    crypto/secp,
  ]

import ../../tools/[lifecycle, unittest]
import ./utils

suite "Spam Protection Component":
  asyncTeardown:
    checkTrackers()

  asyncTest "rate limiting spam protection":
    const
      numMixNodes = 10
      rateLimitPerNode = 10 # Each node allows this many packets
      numTestPackets = 5 # Number of packets to send in test

    # Each node gets its own spam protection instance with independent rate limit
    # This reflects real-world deployment where each node independently enforces limits
    let nodes = await setupMixNodes(
      numMixNodes,
      destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32))),
      spamProtectionRateLimit = Opt.some(rateLimitPerNode),
    )
    startAndDeferStop(nodes)

    let (destNode, pingProto) = await setupDestNode(Ping.new())
    defer:
      await stopDestNode(destNode)

    # Send packets (within rate limit)
    for i in 0 ..< numTestPackets:
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

  asyncTest "rate limit exceeded - message rejected at intermediate node":
    ## 4 nodes, PathLength=3 => all 3 non-sender nodes are on every path.
    ## Each hop calls verifyProof once, so after 3 messages each node
    ## has hit the rate limit. The 4th message gets dropped mid-path.
    const
      numNodes = 4 # sender + 3 path nodes
      rateLimit = 3

    let nodes =
      await setupMixNodes(numNodes, spamProtectionRateLimit = Opt.some(rateLimit))
    startAndDeferStop(nodes)

    let nrProto = NoReplyProtocol.new()
    let (destNode, _) = await setupDestNode(nrProto)
    defer:
      await stopDestNode(destNode)

    let testPayload = "test message".toBytes()

    # Send 3 messages — all should arrive
    for i in 0 ..< rateLimit:
      let conn = nodes[0]
        .toConnection(
          MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
          NoReplyProtocolCodec,
        )
        .expect("could not build connection")

      await conn.writeLp(testPayload)
      check testPayload == await nrProto.receivedMessages.get().wait(5.seconds)
      await conn.close()

    # 4th message — should be dropped at intermediate node
    let conn = nodes[0]
      .toConnection(
        MixDestination.init(destNode.peerInfo.peerId, destNode.peerInfo.addrs[0]),
        NoReplyProtocolCodec,
      )
      .expect("could not build connection")
    defer:
      await conn.close()

    await conn.writeLp(testPayload)

    expect AsyncTimeoutError:
      discard await nrProto.receivedMessages.get().wait(2.seconds)

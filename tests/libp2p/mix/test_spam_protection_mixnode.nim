# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results
import
  ../../../libp2p/[
    protocols/mix,
    protocols/mix/mix_node,
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
  const
    NumMixNodes = 10
    RateLimitPerNode = 10 # Each node allows this many packets
    NumTestPackets = 5 # Number of packets to send in test

  asyncTeardown:
    checkTrackers()
    deleteNodeInfoFolder()
    deletePubInfoFolder()

  asyncTest "rate limiting spam protection":
    # Each node gets its own spam protection instance with independent rate limit
    # This reflects real-world deployment where each node independently enforces limits
    let nodes = await setupMixNodes(
      NumMixNodes,
      destReadBehavior = Opt.some((codec: PingCodec, callback: readExactly(32))),
      spamProtectionRateLimit = Opt.some(RateLimitPerNode),
    )
    startAndDeferStop(nodes)

    let (destNode, pingProto) = await setupDestNode(Ping.new())
    defer:
      await stopDestNode(destNode)

    # Send packets (within rate limit)
    for i in 0 ..< NumTestPackets:
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

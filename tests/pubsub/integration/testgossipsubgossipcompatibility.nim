# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[sequtils]
import chronicles
import ../utils
import ../../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../../helpers

suite "GossipSub Integration - Compatibility":
  const topic = "foobar"

  teardown:
    checkTrackers()

  asyncTest "Protocol negotiation selects highest common version":
    let
      node0 = generateNodes(
        1,
        gossip = true,
        codecs = @[GossipSubCodec_12, GossipSubCodec_11, GossipSubCodec_10],
          # Order from highest to lowest version is required because
          # multistream protocol negotiation selects the first protocol
          # in the dialer's list that both peers support
      )
      .toGossipSub()[0]
      node1 = generateNodes(
        1, gossip = true, codecs = @[GossipSubCodec_11, GossipSubCodec_10]
      )
      .toGossipSub()[0]
      node2 =
        generateNodes(1, gossip = true, codecs = @[GossipSubCodec_10]).toGossipSub()[0]
      nodes = @[node0, node1, node2]
      node0PeerId = node0.peerInfo.peerId
      node1PeerId = node1.peerInfo.peerId
      node2PeerId = node2.peerInfo.peerId

    startNodesAndDeferStop(nodes)

    await connectNodesStar(nodes)
    nodes.subscribeAllNodes(topic, voidTopicHandler)
    await waitForHeartbeat()

    checkUntilTimeout:
      node0.getPeerByPeerId(topic, node1PeerId).codec == GossipSubCodec_11
      node0.getPeerByPeerId(topic, node2PeerId).codec == GossipSubCodec_10

      node1.getPeerByPeerId(topic, node0PeerId).codec == GossipSubCodec_11
      node1.getPeerByPeerId(topic, node2PeerId).codec == GossipSubCodec_10

      node2.getPeerByPeerId(topic, node0PeerId).codec == GossipSubCodec_10
      node2.getPeerByPeerId(topic, node1PeerId).codec == GossipSubCodec_10

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
  teardown:
    checkTrackers()

  asyncTest "Peer must send right gosspipsub version":
    let
      topic = "foobar"
      node0 = generateNodes(1, gossip = true)[0]
      node1 = generateNodes(1, gossip = true, gossipSubVersion = GossipSubCodec_10)[0]

    startNodesAndDeferStop(@[node0, node1])

    await connectNodes(node0, node1)

    node0.subscribe(topic, voidTopicHandler)
    node1.subscribe(topic, voidTopicHandler)
    await waitSubGraph(@[node0, node1], topic)

    var gossip0: GossipSub = GossipSub(node0)
    var gossip1: GossipSub = GossipSub(node1)

    checkUntilTimeout:
      gossip0.mesh.getOrDefault(topic).toSeq[0].codec == GossipSubCodec_10
    checkUntilTimeout:
      gossip1.mesh.getOrDefault(topic).toSeq[0].codec == GossipSubCodec_10

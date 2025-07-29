{.used.}

import std/[sequtils]
import pubsub/utils
import ../libp2p/protocols/pubsub/[gossipsub]
import helpers

suite "quic":
  teardown:
    checkTrackers()

  asyncTest "Nil":
    const
      numberOfNodes = 10
      topic = "foobar"
      heartbeatInterval = 200.milliseconds
    let
      nodes = generateNodes(
          numberOfNodes, gossip = true, heartbeatInterval = heartbeatInterval
        )
        .toGossipSub()
      node0 = nodes[0]

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)
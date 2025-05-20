{.used.}

import std/[sequtils]
import utils
import chronicles
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../helpers

suite "GossipSub Heartbeat":
  teardown:
    checkTrackers()

  asyncTest "Mesh is rebalanced during heartbeat - grafting new peers":
    let
      numberOfNodes = 10
      topic = "foobar"
      dLow = 3
      dHigh = 4
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          dValues = some(
            DValues(dLow: some(dLow), dHigh: some(dHigh), d: some(3), dOut: some(1))
          ),
          pruneBackoff = 20.milliseconds,
        )
        .toGossipSub()

    startNodesAndDeferStop(nodes)

    # Nodes are connected to Node0
    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      nodes[0].mesh[topic].len >= dLow and nodes[0].mesh[topic].len <= dHigh

    # When peers in mesh of Node0 are disconnected
    let peersToDisconnect = nodes[0].mesh[topic].toSeq()[1 .. ^1].mapIt(it.peerId)

    for i in 1 ..< numberOfNodes:
      let node = nodes[i]
      if any(
        peersToDisconnect,
        proc(p: PeerId): bool =
          p == node.peerInfo.peerId,
      ):
        node.unsubscribe(topic, voidTopicHandler)
        await node.stop()

    # Then mesh of Node0 is rebalanced and new peers are added
    await waitForHeartbeat()

    check:
      nodes[0].mesh[topic].len >= dLow and nodes[0].mesh[topic].len <= dHigh
      all(
        nodes[0].mesh[topic].toSeq(),
        proc(p: PubSubPeer): bool =
          p.peerId notin peersToDisconnect,
      )

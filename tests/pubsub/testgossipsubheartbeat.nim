{.used.}

import std/[sequtils]
import utils
import chronicles
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../helpers

suite "GossipSub Heartbeat":
  teardown:
    checkTrackers()

  asyncTest "Mesh is rebalanced during heartbeat - pruning peers":
    let
      numberOfNodes = 10
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    # Observe timestamps of received prune messages
    var lastPrune = Moment.now()
    for i in 0 ..< numberOfNodes:
      let pubsubObserver = PubSubObserver(
        onRecv: proc(peer: PubSubPeer, msgs: var RPCMsg) =
          if msgs.control.isSome:
            for msg in msgs.control.get.prune:
              lastPrune = Moment.now()
      )
      nodes[i].addObserver(pubsubObserver)

    # Nodes are connected to Node0
    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()
    check:
      nodes[0].mesh[topic].len == 9

    # When DValues of Node0 are updated to lower than defaults
    let newDValues = some(
      DValues(
        dLow: some(2),
        dHigh: some(4),
        d: some(3),
        dLazy: some(3),
        dScore: some(2),
        dOut: some(2),
      )
    )
    nodes[0].parameters.applyDValues(newDValues)

    # Waiting 2 hearbeats to finish pruning (2 peers first and then 3)
    # Comparing timestamps of last received prune to confirm heartbeat interval
    await waitForHeartbeat()
    let after1stHearbeat = lastPrune

    await waitForHeartbeat()
    let after2ndHearbeat = lastPrune

    let measuredHeartbeat = after2ndHearbeat - after1stHearbeat
    let heartbeatDiff = measuredHeartbeat - TEST_GOSSIPSUB_HEARTBEAT_INTERVAL

    # Then mesh of Node0 is rebalanced and peers are pruned to adapt to new values
    check:
      nodes[0].mesh[topic].len >= 2 and nodes[0].mesh[topic].len <= 4
      heartbeatDiff < 2.milliseconds # 2ms margin

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

  asyncTest "Fanout maintanance - expired peers are dropped during heartbeat":
    let
      numberOfNodes = 10
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true, fanoutTTL = 30.milliseconds)
        .toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    # All nodes but Node0 are subscribed to the topic
    for node in nodes[1 .. ^1]:
      node.subscribe(topic, voidTopicHandler)
    await waitForHeartbeat()

    # When Node0 sends a message to the topic
    let node0 = nodes[0]
    tryPublish await node0.publish(topic, newSeq[byte](10000)), 1

    # Then fanout peers are populated
    await waitForPeersInTable(node0, topic, 6, PeerTableType.Fanout)
    check:
      node0.fanout.hasKey(topic) and node0.fanout[topic].len == 6

    # And after heartbeat (60ms) fanout peers are dropped (because fanoutTTL=30ms)
    await waitForHeartbeat()
    check:
      not node0.fanout.hasKey(topic)

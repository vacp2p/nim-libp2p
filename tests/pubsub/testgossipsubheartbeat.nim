{.used.}

import std/[sequtils]
import utils
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
      node0 = nodes[0]

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
      await connectNodes(node0, nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()
    check:
      node0.mesh[topic].len == 9

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
    node0.parameters.applyDValues(newDValues)

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
      node0.mesh[topic].len >= 2 and node0.mesh[topic].len <= 4
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
      node0 = nodes[0]

    startNodesAndDeferStop(nodes)

    # Nodes are connected to Node0
    for i in 1 ..< numberOfNodes:
      await connectNodes(node0, nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      node0.mesh[topic].len >= dLow and node0.mesh[topic].len <= dHigh

    # When peers of Node0 mesh are disconnected
    let peersToDisconnect = node0.mesh[topic].toSeq()[1 .. ^1].mapIt(it.peerId)
    await findAndStopPeers(nodes, peersToDisconnect, topic, voidTopicHandler)

    # Then mesh of Node0 is rebalanced and new peers are added
    await waitForHeartbeat()

    check:
      node0.mesh[topic].len >= dLow and node0.mesh[topic].len <= dHigh
      node0.mesh[topic].toSeq().allIt(it.peerId notin peersToDisconnect)

  asyncTest "Mesh is rebalanced during heartbeat - opportunistic grafting":
    let
      numberOfNodes = 10
      topic = "foobar"
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          dValues = some(
            DValues(
              dLow: some(3),
              dHigh: some(4),
              d: some(3),
              dOut: some(1),
              dLazy: some(3),
              dScore: some(2),
            )
          ),
          pruneBackoff = 20.milliseconds,
          opportunisticGraftThreshold = 600,
        )
        .toGossipSub()
      node0 = nodes[0]

    startNodesAndDeferStop(nodes)

    # Nodes are connected to Node0
    for i in 1 ..< numberOfNodes:
      await connectNodes(node0, nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # Keep track of initial mesh of Node0
    let startingMesh = node0.mesh[topic].toSeq()

    # When scores are assigned to Peers of Node0
    var expectedGrafts: seq[PubSubPeer] = @[]
    var score = 100.0
    for peer in node0.gossipsub[topic]:
      if peer in node0.mesh[topic]:
        # Assign scores in starting Mesh
        peer.score = score
        score += 100.0
      else:
        # Assign scores higher than median to Peers not in starting Mesh and expect them to be grafted
        peer.score = 800.0
        expectedGrafts &= peer

    # Then during heartbeat Peers with lower than median scores are pruned and max 2 Peers are grafted
    await waitForHeartbeat()

    let actualGrafts = node0.mesh[topic].toSeq().filterIt(it notin startingMesh)
    check:
      actualGrafts.len == 2
      actualGrafts.allIt(it in expectedGrafts)

  asyncTest "Fanout maintenance during heartbeat - expired peers are dropped":
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

    # Then Node0 fanout peers are populated
    await waitForPeersInTable(node0, topic, 6, PeerTableType.Fanout)
    check:
      node0.fanout.hasKey(topic) and node0.fanout[topic].len == 6

    # And after heartbeat (60ms) Node0 fanout peers are dropped (because fanoutTTL=30ms)
    await waitForHeartbeat()
    check:
      not node0.fanout.hasKey(topic)

  asyncTest "Fanout maintenance during heartbeat - fanout peers are replenished":
    let
      numberOfNodes = 10
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()
      node0 = nodes[0]

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    # All nodes but Node0 are subscribed  to the topic
    for node in nodes[1 .. ^1]:
      node.subscribe(topic, voidTopicHandler)
    await waitForHeartbeat()

    # When Node0 sends a message to the topic
    tryPublish await node0.publish(topic, newSeq[byte](10000)), 1

    # Then Node0 fanout peers are populated
    await waitForPeersInTable(node0, topic, 6, PeerTableType.Fanout)
    check:
      node0.fanout.hasKey(topic) and node0.fanout[topic].len == 6

    # When peers of Node0 fanout are disconnected
    let peersToDisconnect = node0.fanout[topic].toSeq()[1 .. ^1].mapIt(it.peerId)
    await findAndStopPeers(nodes, peersToDisconnect, topic, voidTopicHandler)
    await waitForPeersInTable(node0, topic, 1, PeerTableType.Fanout)

    # Then Node0 fanout peers are replenished during heartbeat
    await waitForHeartbeat()
    check:
      node0.fanout[topic].len == 4
      node0.fanout[topic].toSeq().allIt(it.peerId notin peersToDisconnect)

  asyncTest "iDontWants history - last element is pruned during heartbeat":
    let
      topic = "foobar"
      nodes = generateNodes(
          2, gossip = true, sendIDontWantOnPublish = true, historyLength = 5
        )
        .toGossipSub()

    startNodesAndDeferStop(nodes)

    await connectNodes(nodes[0], nodes[1])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # When Node0 sends 10 messages to the topic
    for i in 0 ..< 10:
      tryPublish await nodes[0].publish(topic, newSeq[byte](1000)), 1

    # Then Node1 receives 10 iDontWant messages from Node0
    let peer = nodes[1].mesh[topic].toSeq()[0]
    check:
      peer.iDontWants[^1].len == 10

    # When heartbeat happens
    await waitForHeartbeat()

    # Then last element of iDontWants history is pruned
    check:
      peer.iDontWants[^1].len == 0

  asyncTest "sentIHaves history - last element is pruned during heartbeat":
    # 3 Nodes, Node 0 <==> Node 1 and Node 0 <==> Node 2
    # due to DValues: 1 peer in mesh and 1 peer only in gossip of Node 0
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          historyLength = 3,
          dValues =
            some(DValues(dLow: some(1), dHigh: some(1), d: some(1), dOut: some(0))),
        )
        .toGossipSub()

    startNodesAndDeferStop(nodes)

    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)

    # Waiting 2 heartbeats to populate sentIHaves history
    await waitForHeartbeat(2)

    # When Node0 sends a messages to the topic
    for i in 0 ..< 1:
      tryPublish await nodes[0].publish(topic, newSeq[byte](1000)), 1

    # Find Peer outside of mesh to which Node 0 will send IHave
    let peer =
      nodes[0].gossipsub[topic].toSeq().filterIt(it notin nodes[0].mesh[topic])[0]

    # When next heartbeat occurs
    # Then IHave is sent and sentIHaves is populated
    waitForCondition(
      peer.sentIHaves[^1].len > 0,
      10.milliseconds,
      100.milliseconds,
      "wait for sentIHaves timeout",
    )

    # Need to clear mCache as node would keep populating sentIHaves
    nodes[0].clearMCache()

    # When next heartbeat occurs 
    await waitForHeartbeat()

    # Then last element of sentIHaves history is pruned 
    check:
      peer.sentIHaves[^1].len == 0

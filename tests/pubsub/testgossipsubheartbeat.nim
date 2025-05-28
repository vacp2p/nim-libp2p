{.used.}

import std/[sequtils]
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../helpers

suite "GossipSub Heartbeat":
  teardown:
    checkTrackers()

  const
    timeout = 1.seconds
    interval = 50.milliseconds

  asyncTest "Mesh is rebalanced during heartbeat - pruning peers":
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

    # Nodes are connected to Node0
    for i in 1 ..< numberOfNodes:
      await connectNodes(node0, nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)

    checkUntilCustomTimeout(timeout, interval):
      node0.mesh.getOrDefault(topic).len == numberOfNodes - 1

    # When DValues of Node0 are updated to lower than defaults
    const
      newDLow = 2
      newDHigh = 4
      newDValues = some(
        DValues(
          dLow: some(newDLow),
          dHigh: some(newDHigh),
          d: some(3),
          dLazy: some(3),
          dScore: some(2),
          dOut: some(2),
        )
      )
    node0.parameters.applyDValues(newDValues)

    # Then mesh of Node0 is rebalanced and peers are pruned to adapt to new values
    checkUntilCustomTimeout(timeout, interval):
      node0.mesh[topic].len >= newDLow and node0.mesh[topic].len <= newDHigh

  asyncTest "Mesh is rebalanced during heartbeat - grafting new peers":
    const
      numberOfNodes = 10
      topic = "foobar"
      dLow = 3
      dHigh = 4
      heartbeatInterval = 200.milliseconds
    let
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          dValues = some(
            DValues(dLow: some(dLow), dHigh: some(dHigh), d: some(3), dOut: some(1))
          ),
          pruneBackoff = 20.milliseconds,
          heartbeatInterval = heartbeatInterval,
        )
        .toGossipSub()
      node0 = nodes[0]

    startNodesAndDeferStop(nodes)

    # Nodes are connected to Node0
    for i in 1 ..< numberOfNodes:
      await connectNodes(node0, nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)

    checkUntilCustomTimeout(timeout, interval):
      node0.mesh.getOrDefault(topic).len >= dLow and
        node0.mesh.getOrDefault(topic).len <= dHigh

    # When peers of Node0 mesh are disconnected
    let peersToDisconnect = node0.mesh[topic].toSeq()[1 .. ^1].mapIt(it.peerId)
    findAndUnsubscribePeers(nodes, peersToDisconnect, topic, voidTopicHandler)

    checkUntilCustomTimeout(timeout, interval):
      node0.mesh[topic].len >= dLow and node0.mesh[topic].len <= dHigh
      node0.mesh[topic].toSeq().allIt(it.peerId notin peersToDisconnect)

  asyncTest "Mesh is rebalanced during heartbeat - opportunistic grafting":
    const
      numberOfNodes = 10
      topic = "foobar"
      heartbeatInterval = 200.milliseconds
    let
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
          heartbeatInterval = heartbeatInterval,
        )
        .toGossipSub()
      node0 = nodes[0]

    startNodesAndDeferStop(nodes)

    # Nodes are connected to Node0
    for i in 1 ..< numberOfNodes:
      await connectNodes(node0, nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat(heartbeatInterval)

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
    await waitForHeartbeat(heartbeatInterval)

    let actualGrafts = node0.mesh[topic].toSeq().filterIt(it notin startingMesh)
    const maxOpportunisticGraftsPerHeartbeat = 2
    check:
      actualGrafts.len == maxOpportunisticGraftsPerHeartbeat
      actualGrafts.allIt(it in expectedGrafts)

  asyncTest "Fanout maintenance during heartbeat - expired peers are dropped":
    const
      numberOfNodes = 10
      topic = "foobar"
      heartbeatInterval = 200.milliseconds
    let nodes = generateNodes(
        numberOfNodes,
        gossip = true,
        fanoutTTL = 60.milliseconds,
        heartbeatInterval = heartbeatInterval,
      )
      .toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    # All nodes but Node0 are subscribed to the topic
    for node in nodes[1 .. ^1]:
      node.subscribe(topic, voidTopicHandler)
    await waitForHeartbeat(heartbeatInterval)

    # When Node0 sends a message to the topic
    let node0 = nodes[0]
    tryPublish await node0.publish(topic, newSeq[byte](10000)), 3

    # Then Node0 fanout peers are populated
    let maxFanoutPeers = node0.parameters.d
    checkUntilCustomTimeout(timeout, interval):
      node0.fanout.hasKey(topic) and node0.fanout[topic].len == maxFanoutPeers

    # And after heartbeat Node0 fanout peers are dropped (because fanoutTTL < heartbeatInterval)
    checkUntilCustomTimeout(timeout, interval):
      not node0.fanout.hasKey(topic)

  asyncTest "Fanout maintenance during heartbeat - fanout peers are replenished":
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

    # All nodes but Node0 are subscribed  to the topic
    for node in nodes[1 .. ^1]:
      node.subscribe(topic, voidTopicHandler)
    await waitForHeartbeat(heartbeatInterval)

    # When Node0 sends a message to the topic
    tryPublish await node0.publish(topic, newSeq[byte](10000)), 1

    # Then Node0 fanout peers are populated 
    let maxFanoutPeers = node0.parameters.d
    checkUntilCustomTimeout(timeout, interval):
      node0.fanout[topic].len == maxFanoutPeers

    # When all peers but first one of Node0 fanout are disconnected
    let peersToDisconnect = node0.fanout[topic].toSeq()[1 .. ^1].mapIt(it.peerId)
    findAndUnsubscribePeers(nodes, peersToDisconnect, topic, voidTopicHandler)

    # Then Node0 fanout peers are replenished during heartbeat
    # expecting 10[numberOfNodes] - 1[Node0] - (6[maxFanoutPeers] - 1[first peer not disconnected]) = 4
    let expectedLen = numberOfNodes - 1 - (maxFanoutPeers - 1)
    checkUntilCustomTimeout(timeout, interval):
      node0.fanout[topic].len == expectedLen
      node0.fanout[topic].toSeq().allIt(it.peerId notin peersToDisconnect)

  asyncTest "iDontWants history - last element is pruned during heartbeat":
    const
      topic = "foobar"
      historyLength = 5
      heartbeatInterval = 200.milliseconds
    let nodes = generateNodes(
        2,
        gossip = true,
        sendIDontWantOnPublish = true,
        historyLength = historyLength,
        heartbeatInterval = heartbeatInterval,
      )
      .toGossipSub()

    startNodesAndDeferStop(nodes)

    await connectNodes(nodes[0], nodes[1])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat(heartbeatInterval)

    # Get Node0 as Peer of Node1 
    let peer = nodes[1].mesh[topic].toSeq()[0]

    # Wait for history to populate
    checkUntilCustomTimeout(timeout, interval):
      peer.iDontWants.len == historyLength

    # When Node0 sends 5 messages to the topic
    const msgCount = 5
    for i in 0 ..< msgCount:
      tryPublish await nodes[0].publish(topic, newSeq[byte](1000)), 1

    # Then Node1 receives 5 iDontWant messages from Node0
    checkUntilCustomTimeout(timeout, interval):
      peer.iDontWants[^1].len == msgCount

    # When heartbeat happens
    # Then last element of iDontWants history is pruned
    checkUntilCustomTimeout(timeout, interval):
      peer.iDontWants[^1].len == 0

  asyncTest "sentIHaves history - last element is pruned during heartbeat":
    # 3 Nodes, Node 0 <==> Node 1 and Node 0 <==> Node 2
    # due to DValues: 1 peer in mesh and 1 peer only in gossip of Node 0
    const
      numberOfNodes = 3
      topic = "foobar"
      heartbeatInterval = 200.milliseconds
      historyLength = 3
    let nodes = generateNodes(
        numberOfNodes,
        gossip = true,
        historyLength = historyLength,
        dValues =
          some(DValues(dLow: some(1), dHigh: some(1), d: some(1), dOut: some(0))),
        heartbeatInterval = heartbeatInterval,
      )
      .toGossipSub()

    startNodesAndDeferStop(nodes)

    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat(heartbeatInterval)

    # Find Peer outside of mesh to which Node 0 will send IHave
    let peer =
      nodes[0].gossipsub[topic].toSeq().filterIt(it notin nodes[0].mesh[topic])[0]

    # Wait for history to populate
    checkUntilCustomTimeout(timeout, interval):
      peer.sentIHaves.len == historyLength

    # When Node0 sends a messages to the topic
    tryPublish await nodes[0].publish(topic, newSeq[byte](1000)), 1

    # When next heartbeat occurs
    # Then IHave is sent and sentIHaves is populated 
    checkUntilCustomTimeout(timeout, interval):
      peer.sentIHaves[^1].len == 1

    # Need to clear mCache as node would keep populating sentIHaves
    nodes[0].clearMCache()

    # When next heartbeat occurs 
    # Then last element of sentIHaves history is pruned 
    checkUntilCustomTimeout(timeout, interval):
      peer.sentIHaves[^1].len == 0

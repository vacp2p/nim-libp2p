# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[sequtils]
import stew/byteutils
import utils
import chronicles
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../helpers, ../utils/[futures]

suite "GossipSub Mesh Management":
  teardown:
    checkTrackers()

  asyncTest "topic params":
    let params = TopicParams.init()
    params.validateParameters().tryGet()

  asyncTest "subscribe/unsubscribeAll":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(topic: string, data: seq[byte]): Future[void] {.gcsafe, raises: [].} =
      discard

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)

    # test via dynamic dispatch
    gossipSub.PubSub.subscribe(topic, handler)

    check:
      gossipSub.topics.contains(topic)
      gossipSub.gossipsub[topic].len() > 0
      gossipSub.mesh[topic].len() > 0

    # test via dynamic dispatch
    gossipSub.PubSub.unsubscribeAll(topic)

    check:
      topic notin gossipSub.topics # not in local topics
      topic notin gossipSub.mesh # not in mesh
      topic in gossipSub.gossipsub # but still in gossipsub table (for fanning out)

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`rebalanceMesh` Degree Lo":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "rebalanceMesh - bad peers":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    var scoreLow = -11'f64
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      peer.score = scoreLow
      gossipSub.gossipsub[topic].incl(peer)
      scoreLow += 1.0

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    # low score peers should not be in mesh, that's why the count must be 4
    check gossipSub.mesh[topic].len == 4
    for peer in gossipSub.mesh[topic]:
      check peer.score >= 0.0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`rebalanceMesh` Degree Hi":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      gossipSub.grafted(peer, topic)
      gossipSub.mesh[topic].incl(peer)

    check gossipSub.mesh[topic].len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len ==
      gossipSub.parameters.d + gossipSub.parameters.dScore

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "rebalanceMesh fail due to backoff":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)

      gossipSub.backingOff.mgetOrPut(topic, initTable[PeerId, Moment]()).add(
        peerId, Moment.now() + 1.hours
      )
      let prunes = gossipSub.handleGraft(peer, @[ControlGraft(topicID: topic)])
      # there must be a control prune due to violation of backoff
      check prunes.len != 0

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    # expect 0 since they are all backing off
    check gossipSub.mesh[topic].len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "rebalanceMesh fail due to backoff - remote":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)
      gossipSub.mesh[topic].incl(peer)

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len != 0

    for i in 0 ..< 15:
      let peerId = conns[i].peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      gossipSub.handlePrune(
        peer,
        @[
          ControlPrune(
            topicID: topic,
            peers: @[],
            backoff: gossipSub.parameters.pruneBackoff.seconds.uint64,
          )
        ],
      )

    # expect topic cleaned up since they are all pruned
    check topic notin gossipSub.mesh

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "rebalanceMesh Degree Hi - audit scenario":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    let topic = "foobar"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.parameters.dScore = 4
    gossipSub.parameters.d = 6
    gossipSub.parameters.dOut = 3
    gossipSub.parameters.dHigh = 12
    gossipSub.parameters.dLow = 4

    var conns = newSeq[Connection]()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    for i in 0 ..< 6:
      let conn = TestBufferStream.new(noop)
      conn.transportDir = Direction.In
      conns &= conn
      let peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.score = 40.0
      peer.sendConn = conn
      gossipSub.grafted(peer, topic)
      gossipSub.mesh[topic].incl(peer)

    for i in 0 ..< 7:
      let conn = TestBufferStream.new(noop)
      conn.transportDir = Direction.Out
      conns &= conn
      let peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.score = 10.0
      peer.sendConn = conn
      gossipSub.grafted(peer, topic)
      gossipSub.mesh[topic].incl(peer)

    check gossipSub.mesh[topic].len == 13
    gossipSub.rebalanceMesh(topic)
    # ensure we are above dlow
    check gossipSub.mesh[topic].len > gossipSub.parameters.dLow
    var outbound = 0
    for peer in gossipSub.mesh[topic]:
      if peer.sendConn.transportDir == Direction.Out:
        inc outbound
    # ensure we give priority and keep at least dOut outbound peers
    check outbound >= gossipSub.parameters.dOut

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "dont prune peers if mesh len is less than d_high":
    let
      numberOfNodes = 5
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)

    let expectedNumberOfPeers = numberOfNodes - 1
    await waitForPeersInTable(
      nodes,
      topic,
      newSeqWith(numberOfNodes, expectedNumberOfPeers),
      PeerTableType.Gossipsub,
    )

    for i in 0 ..< numberOfNodes:
      var gossip = GossipSub(nodes[i])
      check:
        gossip.gossipsub[topic].len == expectedNumberOfPeers
        gossip.mesh[topic].len == expectedNumberOfPeers
        gossip.fanout.len == 0

  asyncTest "prune peers if mesh len is higher than d_high":
    let
      numberOfNodes = 15
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)

    let
      expectedNumberOfPeers = numberOfNodes - 1
      dHigh = 12
      d = 6
      dLow = 4

    await waitForPeersInTable(
      nodes,
      topic,
      newSeqWith(numberOfNodes, expectedNumberOfPeers),
      PeerTableType.Gossipsub,
    )

    for i in 0 ..< numberOfNodes:
      var gossip = GossipSub(nodes[i])

      check:
        gossip.gossipsub[topic].len == expectedNumberOfPeers
        gossip.mesh[topic].len >= dLow and gossip.mesh[topic].len <= dHigh
        gossip.fanout.len == 0

  asyncTest "GossipSub unsub - resub faster than backoff":
    # For this test to work we'd require a way to disable fanout.
    # There's not a way to toggle it, and mocking it didn't work as there's not a reliable mock available.
    skip()
    return

    # Instantiate handlers and validators
    var handlerFut0 = newFuture[bool]()
    proc handler0(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      handlerFut0.complete(true)

    var handlerFut1 = newFuture[bool]()
    proc handler1(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      handlerFut1.complete(true)

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      check topic == "foobar"
      validatorFut.complete(true)
      result = ValidationResult.Accept

    # Setup nodes and start switches
    let
      nodes = generateNodes(2, gossip = true, unsubscribeBackoff = 5.seconds)
      topic = "foobar"

    # Connect nodes
    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    # Subscribe both nodes to the topic and node1 (receiver) to the validator
    nodes[0].subscribe(topic, handler0)
    nodes[1].subscribe(topic, handler1)
    nodes[1].addValidator("foobar", validator)
    await sleepAsync(DURATION_TIMEOUT)

    # Wait for both nodes to verify others' subscription
    var subs: seq[Future[void]]
    subs &= waitSub(nodes[1], nodes[0], topic)
    subs &= waitSub(nodes[0], nodes[1], topic)
    await allFuturesThrowing(subs)

    # When unsubscribing and resubscribing in a short time frame, the backoff period should be triggered
    nodes[1].unsubscribe(topic, handler1)
    await sleepAsync(DURATION_TIMEOUT)
    nodes[1].subscribe(topic, handler1)
    await sleepAsync(DURATION_TIMEOUT)

    # Backoff is set to 5 seconds, and the amount of sleeping time since the unsubsribe until now is 3-4s~
    # Meaning, the subscription shouldn't have been processed yet because it's still in backoff period
    # When publishing under this condition
    discard await nodes[0].publish("foobar", "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # Then the message should not be received:
    check:
      validatorFut.toState().isPending()
      handlerFut1.toState().isPending()
      handlerFut0.toState().isPending()

    validatorFut.reset()
    handlerFut0.reset()
    handlerFut1.reset()

    # If we wait backoff period to end, around 1-2s
    await waitForMesh(nodes[0], nodes[1], topic, 3.seconds)

    discard await nodes[0].publish("foobar", "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # Then the message should be received
    check:
      validatorFut.toState().isCompleted()
      handlerFut1.toState().isCompleted()
      handlerFut0.toState().isPending()

  asyncTest "e2e - GossipSub should add remote peer topic subscriptions":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe("foobar", handler)

    let gossip1 = GossipSub(nodes[0])
    let gossip2 = GossipSub(nodes[1])

    checkUntilTimeout:
      "foobar" in gossip2.topics
      "foobar" in gossip1.gossipsub
      gossip1.gossipsub.hasPeerId("foobar", gossip2.peerInfo.peerId)

  asyncTest "e2e - GossipSub should add remote peer topic subscriptions if both peers are subscribed":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    var subs: seq[Future[void]]
    subs &= waitSub(nodes[1], nodes[0], "foobar")
    subs &= waitSub(nodes[0], nodes[1], "foobar")

    await allFuturesThrowing(subs)

    let
      gossip1 = GossipSub(nodes[0])
      gossip2 = GossipSub(nodes[1])

    check:
      "foobar" in gossip1.topics
      "foobar" in gossip2.topics

      "foobar" in gossip1.gossipsub
      "foobar" in gossip2.gossipsub

      gossip1.gossipsub.hasPeerId("foobar", gossip2.peerInfo.peerId) or
        gossip1.mesh.hasPeerId("foobar", gossip2.peerInfo.peerId)

      gossip2.gossipsub.hasPeerId("foobar", gossip1.peerInfo.peerId) or
        gossip2.mesh.hasPeerId("foobar", gossip1.peerInfo.peerId)

  asyncTest "GossipSub invalid topic subscription":
    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      handlerFut.complete(true)

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)

    # We must subscribe before setting the validator
    nodes[0].subscribe("foobar", handler)

    var gossip = GossipSub(nodes[0])
    let invalidDetected = newFuture[void]()
    gossip.subscriptionValidator = proc(topic: string): bool =
      if topic == "foobar":
        try:
          invalidDetected.complete()
        except:
          raise newException(Defect, "Exception during subscriptionValidator")
        false
      else:
        true

    await connectNodesStar(nodes)

    nodes[1].subscribe("foobar", handler)

    await invalidDetected.wait(10.seconds)

  asyncTest "GossipSub test directPeers":
    let nodes = generateNodes(2, gossip = true)
    startNodesAndDeferStop(nodes)

    await GossipSub(nodes[0]).addDirectPeer(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )

    let invalidDetected = newFuture[void]()
    GossipSub(nodes[0]).subscriptionValidator = proc(topic: string): bool =
      if topic == "foobar":
        try:
          invalidDetected.complete()
        except:
          raise newException(Defect, "Exception during subscriptionValidator")
        false
      else:
        true

    # DO NOT SUBSCRIBE, CONNECTION SHOULD HAPPEN
    ### await connectNodesStar(nodes)

    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    nodes[1].subscribe("foobar", handler)

    await invalidDetected.wait(10.seconds)

  asyncTest "mesh and gossipsub updated when topic subscribed and unsubscribed":
    let
      numberOfNodes = 5
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    # When all of them are connected and subscribed to the same topic
    await connectNodesStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # Then mesh and gossipsub should be populated
    for node in nodes:
      check node.topics.contains(topic)
      check node.gossipsub.hasKey(topic)
      check node.gossipsub[topic].len() == numberOfNodes - 1
      check node.mesh.hasKey(topic)
      check node.mesh[topic].len() == numberOfNodes - 1

    # When all nodes unsubscribe from the topic
    unsubscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # Then the topic should be removed from mesh and gossipsub
    for node in nodes:
      check topic notin node.topics
      check topic notin node.mesh
      check topic notin node.gossipsub

  asyncTest "handle subscribe and unsubscribe for multiple topics":
    let
      numberOfNodes = 3
      topics = @["foobar1", "foobar2", "foobar3"]
      nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    # When nodes subscribe to multiple topics
    await connectNodesStar(nodes)
    for topic in topics:
      subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # Then all nodes should be subscribed to the topics initially
    for node in nodes:
      for topic in topics:
        check node.topics.contains(topic)
        check node.gossipsub[topic].len() == numberOfNodes - 1
        check node.mesh[topic].len() == numberOfNodes - 1

    # When they unsubscribe from all topics
    for topic in topics:
      unsubscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # Then topics should be removed from mesh and gossipsub
    for node in nodes:
      for topic in topics:
        check topic notin node.topics
        check topic notin node.mesh
        check topic notin node.gossipsub

  asyncTest "GRAFT messages correctly add peers to mesh":
    # Given 2 nodes
    let
      topic = "foobar"
      graftMessage = ControlMessage(graft: @[ControlGraft(topicID: topic)])
      numberOfNodes = 2
      # First part of the hack: Weird dValues so peers are not GRAFTed automatically
      dValues = DValues(dLow: some(0), dHigh: some(0), d: some(0), dOut: some(-1))
      nodes = generateNodes(
          numberOfNodes, gossip = true, verifySignature = false, dValues = some(dValues)
        )
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both subscribe to the topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # Because of the hack-ish dValues, the peers are added to gossipsub but not GRAFTed to mesh
    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # Stop both nodes in order to prevent GRAFT message to be sent by heartbeat 
    await n0.stop()
    await n1.stop()

    # Second part of the hack
    # Set values so peers can be GRAFTed
    let newDValues =
      some(DValues(dLow: some(1), dHigh: some(1), d: some(1), dOut: some(1)))
    n0.parameters.applyDValues(newDValues)
    n1.parameters.applyDValues(newDValues)

    # When a GRAFT message is sent
    let p0 = n1.getOrCreatePeer(n0.peerInfo.peerId, @[GossipSubCodec_12])
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(graftMessage)), isHighPriority = false)
    n1.broadcast(@[p0], RPCMsg(control: some(graftMessage)), isHighPriority = false)

    await waitForPeersInTable(
      nodes, topic, newSeqWith(numberOfNodes, 1), PeerTableType.Mesh
    )

    # Then the peers are GRAFTed
    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "Received GRAFT for non-subscribed topic":
    # Given 2 nodes
    let
      topic = "foo"
      graftMessage = ControlMessage(graft: @[ControlGraft(topicID: topic)])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And only node0 subscribes to the topic
    nodes[0].subscribe(topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      n0.topics.hasKey(topic)
      not n1.topics.hasKey(topic)
      not n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # When a GRAFT message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(graftMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer is not GRAFTed
    check:
      n0.topics.hasKey(topic)
      not n1.topics.hasKey(topic)
      not n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "PRUNE messages correctly removes peers from mesh":
    # Given 2 nodes
    let
      topic = "foo"
      backoff = 1
      pruneMessage = ControlMessage(
        prune: @[ControlPrune(topicID: topic, peers: @[], backoff: uint64(backoff))]
      )
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both subscribe to the topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # When a PRUNE message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(pruneMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer is PRUNEd
    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # When another PRUNE message is sent
    let p0 = n1.getOrCreatePeer(n0.peerInfo.peerId, @[GossipSubCodec_12])
    n1.broadcast(@[p0], RPCMsg(control: some(pruneMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer is PRUNEd
    check:
      n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

  asyncTest "Received PRUNE for non-subscribed topic":
    # Given 2 nodes
    let
      topic = "foo"
      pruneMessage =
        ControlMessage(prune: @[ControlPrune(topicID: topic, peers: @[], backoff: 1)])
      numberOfNodes = 2
      nodes = generateNodes(numberOfNodes, gossip = true, verifySignature = false)
        .toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And only node0 subscribes to the topic
    n0.subscribe(topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      n0.topics.hasKey(topic)
      not n1.topics.hasKey(topic)
      not n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

    # When a PRUNE message is sent
    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_12])
    n0.broadcast(@[p1], RPCMsg(control: some(pruneMessage)), isHighPriority = false)
    await waitForHeartbeat()

    # Then the peer is not PRUNEd
    check:
      n0.topics.hasKey(topic)
      not n1.topics.hasKey(topic)
      not n0.gossipsub.hasPeerId(topic, n1.peerInfo.peerId)
      n1.gossipsub.hasPeerId(topic, n0.peerInfo.peerId)
      not n0.mesh.hasPeerId(topic, n1.peerInfo.peerId)
      not n1.mesh.hasPeerId(topic, n0.peerInfo.peerId)

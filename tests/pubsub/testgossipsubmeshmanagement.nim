# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

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
    let topic = "foobar"
    let (gossipSub, conns, peers) =
      setupGossipSubWithPeers(15, topic, populateGossipsub = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # test via dynamic dispatch
    gossipSub.PubSub.subscribe(topic, voidTopicHandler)

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

  asyncTest "`rebalanceMesh` Degree Lo":
    let topic = "foobar"
    let (gossipSub, conns, peers) =
      setupGossipSubWithPeers(15, topic, populateGossipsub = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len == gossipSub.parameters.d

  asyncTest "rebalanceMesh - bad peers":
    let topic = "foobar"
    let (gossipSub, conns, peers) =
      setupGossipSubWithPeers(15, topic, populateGossipsub = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    var scoreLow = -11'f64
    for peer in peers:
      peer.score = scoreLow
      scoreLow += 1.0

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    # low score peers should not be in mesh, that's why the count must be 4
    check gossipSub.mesh[topic].len == 4
    for peer in gossipSub.mesh[topic]:
      check peer.score >= 0.0

  asyncTest "`rebalanceMesh` Degree Hi":
    let topic = "foobar"
    let (gossipSub, conns, peers) =
      setupGossipSubWithPeers(15, topic, populateGossipsub = true, populateMesh = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    check gossipSub.mesh[topic].len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len ==
      gossipSub.parameters.d + gossipSub.parameters.dScore

  asyncTest "rebalanceMesh fail due to backoff":
    let topic = "foobar"
    let (gossipSub, conns, peers) =
      setupGossipSubWithPeers(15, topic, populateGossipsub = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    for peer in peers:
      gossipSub.backingOff.mgetOrPut(topic, initTable[PeerId, Moment]()).add(
        peer.peerId, Moment.now() + 1.hours
      )
      let prunes = gossipSub.handleGraft(peer, @[ControlGraft(topicID: topic)])
      # there must be a control prune due to violation of backoff
      check prunes.len != 0

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    # expect 0 since they are all backing off
    check gossipSub.mesh[topic].len == 0

  asyncTest "rebalanceMesh fail due to backoff - remote":
    let topic = "foobar"
    let (gossipSub, conns, peers) =
      setupGossipSubWithPeers(15, topic, populateGossipsub = true, populateMesh = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    check gossipSub.peers.len == 15
    gossipSub.rebalanceMesh(topic)
    check gossipSub.mesh[topic].len != 0

    for peer in peers:
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

  asyncTest "rebalanceMesh Degree Hi - audit scenario":
    let
      topic = "foobar"
      numInPeers = 6
      numOutPeers = 7
      totalPeers = numInPeers + numOutPeers

    let (gossipSub, conns, peers) = setupGossipSubWithPeers(
      totalPeers, topic, populateGossipsub = true, populateMesh = true
    )
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.dScore = 4
    gossipSub.parameters.d = 6
    gossipSub.parameters.dOut = 3
    gossipSub.parameters.dHigh = 12
    gossipSub.parameters.dLow = 4

    for i in 0 ..< numInPeers:
      let conn = conns[i]
      let peer = peers[i]
      conn.transportDir = Direction.In
      peer.score = 40.0

    for i in numInPeers ..< totalPeers:
      let conn = conns[i]
      let peer = peers[i]
      conn.transportDir = Direction.Out
      peer.score = 10.0

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

  asyncTest "dont prune peers if mesh len is less than d_high":
    let
      numberOfNodes = 5
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)

    let expectedNumberOfPeers = numberOfNodes - 1

    for i in 0 ..< numberOfNodes:
      let node = nodes[i]
      checkUntilCustomTimeout(500.milliseconds, 20.milliseconds):
        node.gossipsub.getOrDefault(topic).len == expectedNumberOfPeers
        node.mesh.getOrDefault(topic).len == expectedNumberOfPeers
        node.fanout.len == 0

  asyncTest "prune peers if mesh len is higher than d_high":
    let
      numberOfNodes = 15
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)

    let
      expectedNumberOfPeers = numberOfNodes - 1
      dHigh = 12
      d = 6
      dLow = 4

    for i in 0 ..< numberOfNodes:
      let node = nodes[i]
      checkUntilCustomTimeout(500.milliseconds, 20.milliseconds):
        node.gossipsub.getOrDefault(topic).len == expectedNumberOfPeers
        node.mesh.getOrDefault(topic).len >= dLow and
          node.mesh.getOrDefault(topic).len <= dHigh
        node.fanout.len == 0

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
    for i in 0 ..< numberOfNodes:
      let node = nodes[i]
      for j in 0 ..< topics.len:
        let topic = topics[j]
        checkUntilCustomTimeout(500.milliseconds, 20.milliseconds):
          node.topics.contains(topic)
          node.gossipsub[topic].len() == numberOfNodes - 1
          node.mesh[topic].len() == numberOfNodes - 1

    # When they unsubscribe from all topics
    for topic in topics:
      unsubscribeAllNodes(nodes, topic, voidTopicHandler)

    # Then topics should be removed from mesh and gossipsub
    for i in 0 ..< numberOfNodes:
      let node = nodes[i]
      for j in 0 ..< topics.len:
        let topic = topics[j]
        checkUntilCustomTimeout(500.milliseconds, 20.milliseconds):
          topic notin node.topics
          topic notin node.mesh
          topic notin node.gossipsub

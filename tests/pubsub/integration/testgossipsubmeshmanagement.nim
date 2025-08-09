# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronicles
import std/[sequtils]
import ../utils
import ../../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable]
import ../../helpers

suite "GossipSub Integration - Mesh Management":
  teardown:
    checkTrackers()

  asyncTest "Nodes graft peers according to DValues - numberOfNodes < dHigh":
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
      checkUntilTimeout:
        node.gossipsub.getOrDefault(topic).len == expectedNumberOfPeers
        node.mesh.getOrDefault(topic).len == expectedNumberOfPeers
        node.fanout.len == 0

  asyncTest "Nodes graft peers according to DValues - numberOfNodes > dHigh":
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
      checkUntilTimeout:
        node.gossipsub.getOrDefault(topic).len == expectedNumberOfPeers
        node.mesh.getOrDefault(topic).len >= dLow and
          node.mesh.getOrDefault(topic).len <= dHigh
        node.fanout.len == 0

  asyncTest "GossipSub should add remote peer topic subscriptions":
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

  asyncTest "GossipSub should add remote peer topic subscriptions if both peers are subscribed":
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
    for i in 0 ..< topics.len:
      let topic = topics[i]
      checkUntilTimeout:
        nodes.allIt(it.topics.contains(topic))
        nodes.allIt(it.gossipsub.getOrDefault(topic).len() == numberOfNodes - 1)
        nodes.allIt(it.mesh.getOrDefault(topic).len() == numberOfNodes - 1)

    # When they unsubscribe from all topics
    for topic in topics:
      unsubscribeAllNodes(nodes, topic, voidTopicHandler)

    # Then topics should be removed from mesh and gossipsub
    for i in 0 ..< topics.len:
      let topic = topics[i]
      checkUntilTimeout:
        nodes.allIt(not it.topics.contains(topic))
        nodes.allIt(topic notin it.gossipsub)
        nodes.allIt(topic notin it.mesh)

  asyncTest "Unsubscribe backoff":
    const
      numberOfNodes = 3
      topic = "foobar"
      unsubscribeBackoff = 1.seconds # 1s is the minimum
    let nodes = generateNodes(
        numberOfNodes, gossip = true, unsubscribeBackoff = unsubscribeBackoff
      )
      .toGossipSub()

    startNodesAndDeferStop(nodes)

    # Nodes are connected to Node0
    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    check:
      nodes[0].mesh[topic].len == numberOfNodes - 1

    # When Node0 unsubscribes from the topic
    nodes[0].unsubscribe(topic, voidTopicHandler)

    # And subscribes back straight away
    nodes[0].subscribe(topic, voidTopicHandler)

    # Then its mesh is pruned and peers have applied unsubscribeBackoff
    # Waiting more than one heartbeat (60ms) and less than unsubscribeBackoff (1s)
    await sleepAsync(unsubscribeBackoff.div(2))
    check:
      not nodes[0].mesh.hasKey(topic)

    # When unsubscribeBackoff period is done 
    await sleepAsync(unsubscribeBackoff)

    # Then on the next heartbeat mesh is rebalanced and peers are regrafted
    check:
      nodes[0].mesh[topic].len == numberOfNodes - 1

  asyncTest "Prune backoff":
    const
      numberOfNodes = 9
      topic = "foobar"
      pruneBackoff = 1.seconds # 1s is the minimum
      dValues = some(
        DValues(
          dLow: some(6),
          dHigh: some(8),
          d: some(6),
          dLazy: some(6),
          dScore: some(4),
          dOut: some(2),
        )
      )
    let
      nodes = generateNodes(
          numberOfNodes, gossip = true, dValues = dValues, pruneBackoff = pruneBackoff
        )
        .toGossipSub()
      node0 = nodes[0]

    startNodesAndDeferStop(nodes)

    # Nodes are connected to Node0
    for i in 1 ..< numberOfNodes:
      await connectNodes(node0, nodes[i])
    subscribeAllNodes(nodes, topic, voidTopicHandler)

    checkUntilTimeout:
      node0.mesh.getOrDefault(topic).len == numberOfNodes - 1

    # When DValues of Node0 are updated to lower than initial dValues
    const newDValues = some(
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

    # Then Node0 mesh is pruned to newDValues.dHigh length
    # And pruned peers have applied pruneBackoff
    checkUntilTimeout:
      node0.mesh.getOrDefault(topic).len == newDValues.get.dHigh.get

    # When DValues of Node0 are updated back to the initial dValues
    node0.parameters.applyDValues(dValues)

    # Then on the next heartbeat mesh is rebalanced and peers are regrafted to the initial d value
    checkUntilTimeout:
      node0.mesh.getOrDefault(topic).len == dValues.get.d.get

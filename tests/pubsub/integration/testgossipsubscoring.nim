# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[sequtils, strutils]
import stew/byteutils
import ../utils
import ../../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable, pubsubpeer]
import ../../../libp2p/protocols/pubsub/rpc/[messages]
import ../../helpers
import ../../utils/[futures]

suite "GossipSub Integration - Scoring":
  teardown:
    checkTrackers()

  asyncTest "Flood publish to all peers with score above threshold, regardless of subscription":
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true, floodPublish = true)
      g0 = GossipSub(nodes[0])

    startNodesAndDeferStop(nodes)

    # Nodes 1 and 2 are connected to node 0
    await connectNodes(nodes[0], nodes[1])
    await connectNodes(nodes[0], nodes[2])

    let (handlerFut1, handler1) = createCompleteHandler()
    let (handlerFut2, handler2) = createCompleteHandler()

    # Nodes are subscribed to the same topic
    nodes[1].subscribe(topic, handler1)
    nodes[2].subscribe(topic, handler2)
    await waitForHeartbeat()

    # Given node 2's score is below the threshold
    for peer in g0.gossipsub.getOrDefault(topic):
      if peer.peerId == nodes[2].peerInfo.peerId:
        peer.score = (g0.parameters.publishThreshold - 1)

    # When node 0 publishes a message to topic "foo"
    let message = "Hello!".toBytes()
    tryPublish await nodes[0].publish(topic, message), 1

    # Then only node 1 should receive the message
    let results = await waitForStates(@[handlerFut1, handlerFut2], HEARTBEAT_TIMEOUT)
    check:
      results[0].isCompleted(true)
      results[1].isPending()

  asyncTest "Should not rate limit decodable messages below the size allowed":
    const topic = "foobar"
    let
      nodes = generateNodes(
          2,
          gossip = true,
          overheadRateLimit = Opt.some((20, 1.millis)),
          verifySignature = false,
            # Avoid being disconnected by failing signature verification
        )
        .toGossipSub()
      rateLimitHits = currentRateLimitHits()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    nodes[0].broadcast(
      nodes[0].mesh[topic],
      RPCMsg(messages: @[Message(topic: topic, data: newSeq[byte](10))]),
      isHighPriority = true,
    )
    await waitForHeartbeat()

    check:
      currentRateLimitHits() == rateLimitHits
      nodes[1].switch.isConnected(nodes[0].switch.peerInfo.peerId) == true

    # Disconnect peer when rate limiting is enabled
    nodes[1].parameters.disconnectPeerAboveRateLimit = true
    nodes[0].broadcast(
      nodes[0].mesh["foobar"],
      RPCMsg(messages: @[Message(topic: "foobar", data: newSeq[byte](12))]),
      isHighPriority = true,
    )
    await waitForHeartbeat()

    check:
      nodes[1].switch.isConnected(nodes[0].switch.peerInfo.peerId) == true
      currentRateLimitHits() == rateLimitHits

  asyncTest "Should rate limit undecodable messages above the size allowed":
    const topic = "foobar"
    let
      nodes = generateNodes(
          2,
          gossip = true,
          overheadRateLimit = Opt.some((20, 1.millis)),
          verifySignature = false,
            # Avoid being disconnected by failing signature verification
        )
        .toGossipSub()
      rateLimitHits = currentRateLimitHits()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # Simulate sending an undecodable message
    await nodes[1].peers[nodes[0].switch.peerInfo.peerId].sendEncoded(
      newSeqWith(33, 1.byte), isHighPriority = true
    )
    await waitForHeartbeat()

    check:
      currentRateLimitHits() == rateLimitHits + 1
      nodes[1].switch.isConnected(nodes[0].switch.peerInfo.peerId) == true

    # Disconnect peer when rate limiting is enabled
    nodes[1].parameters.disconnectPeerAboveRateLimit = true
    await nodes[0].peers[nodes[1].switch.peerInfo.peerId].sendEncoded(
      newSeqWith(35, 1.byte), isHighPriority = true
    )

    checkUntilTimeout:
      nodes[1].switch.isConnected(nodes[0].switch.peerInfo.peerId) == false
      currentRateLimitHits() == rateLimitHits + 2

  asyncTest "Should rate limit decodable messages above the size allowed":
    const topic = "foobar"
    let
      nodes = generateNodes(
          2,
          gossip = true,
          overheadRateLimit = Opt.some((20, 1.millis)),
          verifySignature = false,
            # Avoid being disconnected by failing signature verification
        )
        .toGossipSub()
      rateLimitHits = currentRateLimitHits()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    let msg = RPCMsg(
      control: some(
        ControlMessage(
          prune:
            @[
              ControlPrune(
                topicID: topic,
                peers: @[PeerInfoMsg(peerId: PeerId(data: newSeq[byte](33)))],
                backoff: 123'u64,
              )
            ]
        )
      )
    )
    nodes[0].broadcast(nodes[0].mesh[topic], msg, isHighPriority = true)
    await waitForHeartbeat()

    check:
      currentRateLimitHits() == rateLimitHits + 1
      nodes[1].switch.isConnected(nodes[0].switch.peerInfo.peerId) == true

    # Disconnect peer when rate limiting is enabled
    nodes[1].parameters.disconnectPeerAboveRateLimit = true
    let msg2 = RPCMsg(
      control: some(
        ControlMessage(
          prune:
            @[
              ControlPrune(
                topicID: topic,
                peers: @[PeerInfoMsg(peerId: PeerId(data: newSeq[byte](35)))],
                backoff: 123'u64,
              )
            ]
        )
      )
    )
    nodes[0].broadcast(nodes[0].mesh[topic], msg2, isHighPriority = true)

    checkUntilTimeout:
      nodes[1].switch.isConnected(nodes[0].switch.peerInfo.peerId) == false
      currentRateLimitHits() == rateLimitHits + 2

  asyncTest "Should rate limit invalid messages above the size allowed":
    const topic = "foobar"
    let
      nodes = generateNodes(
          2,
          gossip = true,
          overheadRateLimit = Opt.some((20, 1.millis)),
          verifySignature = false,
            # Avoid being disconnected by failing signature verification
        )
        .toGossipSub()
      rateLimitHits = currentRateLimitHits()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    proc execValidator(
        topic: string, message: messages.Message
    ): Future[ValidationResult] {.async.} =
      return ValidationResult.Reject

    nodes[0].addValidator(topic, execValidator)
    nodes[1].addValidator(topic, execValidator)

    let msg = RPCMsg(messages: @[Message(topic: topic, data: newSeq[byte](40))])

    nodes[0].broadcast(nodes[0].mesh[topic], msg, isHighPriority = true)
    await waitForHeartbeat()

    check:
      currentRateLimitHits() == rateLimitHits + 1
      nodes[1].switch.isConnected(nodes[0].switch.peerInfo.peerId) == true

    # Disconnect peer when rate limiting is enabled
    nodes[1].parameters.disconnectPeerAboveRateLimit = true
    nodes[0].broadcast(
      nodes[0].mesh[topic],
      RPCMsg(messages: @[Message(topic: topic, data: newSeq[byte](35))]),
      isHighPriority = true,
    )

    checkUntilTimeout:
      nodes[1].switch.isConnected(nodes[0].switch.peerInfo.peerId) == false
      currentRateLimitHits() == rateLimitHits + 2

  asyncTest "DirectPeers: don't kick direct peer with low score":
    const topic = "foobar"
    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await nodes.addDirectPeerStar()

    nodes[1].parameters.disconnectBadPeers = true
    nodes[1].parameters.graylistThreshold = 100000

    var (handlerFut, handler) = createCompleteHandler()
    nodes[0].subscribe(topic, voidTopicHandler)
    nodes[1].subscribe(topic, handler)
    await waitForHeartbeat()

    nodes[1].updateScores()

    # peer shouldn't be in our mesh
    check:
      topic notin nodes[1].mesh
      nodes[1].peerStats[nodes[0].switch.peerInfo.peerId].score <
        nodes[1].parameters.graylistThreshold

    tryPublish await nodes[0].publish(topic, toBytes("hellow")), 1

    # Without directPeers, this would fail
    var futResult = await waitForState(handlerFut)
    check:
      futResult.isCompleted(true)

  asyncTest "Peers disconnections mechanics":
    const
      numberOfNodes = 10
      topic = "foobar"
    let nodes =
      generateNodes(numberOfNodes, gossip = true, triggerSelf = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    var seen: Table[string, int]
    var seenFut = newFuture[void]()
    for i in 0 ..< numberOfNodes:
      let dialer = nodes[i]
      var handler: TopicHandler
      closureScope:
        var peerName = $dialer.peerInfo.peerId
        handler = proc(topicName: string, data: seq[byte]) {.async.} =
          seen.mgetOrPut(peerName, 0).inc()
          check topicName == topic
          if not seenFut.finished() and seen.len >= numberOfNodes:
            seenFut.complete()

      dialer.subscribe(topic, handler)

    await waitSubGraph(nodes, topic)

    # ensure peer stats are stored properly and kept properly
    check:
      nodes[0].peerStats.len == numberOfNodes - 1 # minus self

    tryPublish await nodes[0].publish(topic, toBytes("hello")), 1

    await seenFut.wait(2.seconds)
    check:
      seen.len >= numberOfNodes
    for k, v in seen.pairs:
      check:
        v >= 1

    for node in nodes:
      check:
        topic in node.gossipsub
        node.fanout.len == 0
        node.mesh[topic].len > 0

    # Removing some subscriptions

    for i in 0 ..< numberOfNodes:
      if i mod 3 != 0:
        nodes[i].unsubscribeAll(topic)

    # Waiting 2 heartbeats
    await nodes[0].waitForHeartbeatByEvent(2)

    # ensure peer stats are stored properly and kept properly
    check:
      nodes[0].peerStats.len == numberOfNodes - 1 # minus self

    # Adding again subscriptions
    for i in 0 ..< numberOfNodes:
      if i mod 3 != 0:
        nodes[i].subscribe(topic, voidTopicHandler)

    # Waiting 2 heartbeats
    await nodes[0].waitForHeartbeatByEvent(2)

    # ensure peer stats are stored properly and kept properly
    check:
      nodes[0].peerStats.len == numberOfNodes - 1 # minus self

  asyncTest "DecayInterval":
    const
      topic = "foobar"
      decayInterval = 50.milliseconds
    let nodes =
      generateNodes(2, gossip = true, decayInterval = decayInterval).toGossipSub()

    nodes.setDefaultTopicParams(topic)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    var (handlerFut, handler) = createCompleteHandler()
    nodes[0].subscribe(topic, voidTopicHandler)
    nodes[1].subscribe(topic, handler)

    tryPublish await nodes[0].publish(topic, toBytes("hello")), 1

    var futResult = await waitForState(handlerFut)
    check:
      futResult.isCompleted(true)

    nodes[0].peerStats[nodes[1].peerInfo.peerId].topicInfos[topic].meshMessageDeliveries =
      100
    nodes[0].topicParams[topic].meshMessageDeliveriesDecay = 0.9

    # We should have decayed 5 times, though allowing 4..6
    await sleepAsync(decayInterval * 5)
    check:
      nodes[0].peerStats[nodes[1].peerInfo.peerId].topicInfos[topic].meshMessageDeliveries in
        50.0 .. 66.0

  asyncTest "Invalid messages scoring":
    proc getPeerScore(node: GossipSub, peerNode: GossipSub, topic: string): float64 =
      return node.getPeerByPeerId(topic, peerNode.peerInfo.peerId).score

    proc getInvalidDeliveries(
        node: GossipSub, peerNode: GossipSub, topic: string
    ): float64 =
      node.peerStats.withValue(peerNode.peerInfo.peerId, stats):
        return stats[].topicInfos.getOrDefault(topic).invalidMessageDeliveries

    # Given GossipSub nodes with Topic Params
    const
      topic = "foobar"
      numberOfNodes = 4

    let
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          verifySignature = false,
            # Disable signature verification to isolate validation penalties
          decayInterval = 100.milliseconds, # scoring heartbeat interval
          heartbeatInterval = 5.seconds,
            # heartbeatInterval >>> decayInterval to prevent prunning peers with bad score
          publishThreshold = -150.0,
          graylistThreshold = -200.0,
          disconnectBadPeers = false,
        )
        .toGossipSub()
      centerNode = nodes[0]

    nodes.setDefaultTopicParams(topic)
    for node in nodes:
      node.topicParams[topic].invalidMessageDeliveriesWeight = -10.0
      node.topicParams[topic].invalidMessageDeliveriesDecay = 0.9

    startNodesAndDeferStop(nodes)

    # And Node 0 is center node, connected to all others
    await connectNodes(nodes[0], nodes[1]) # Center to Node 1 (control - valid messages)
    await connectNodes(nodes[0], nodes[2]) # Center to Node 2 (invalid signatures) 
    await connectNodes(nodes[0], nodes[3]) # Center to Node 3 (custom validation failure)

    nodes.subscribeAllNodes(topic, voidTopicHandler)
    await waitForHeartbeat()

    # And center node has messages validator: accept from node 1, reject from nodes 2&3
    var messageCount = 0
    proc validationHandler(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      messageCount.inc
      # Simulate validation logic based on message content 
      let messageStr = string.fromBytes(message.data)
      if messageStr.contains("valid"):
        return ValidationResult.Accept
      else:
        return ValidationResult.Reject # Reject invalid messages

    nodes[0].addValidator(topic, validationHandler)

    checkUntilTimeout:
      centerNode.getPeerScore(nodes[1], topic) > 0
      centerNode.getPeerScore(nodes[2], topic) > 0
      centerNode.getPeerScore(nodes[3], topic) > 0
      centerNode.mesh[topic].toSeq().len == 3

    # When messages are broadcasted
    for i in 0 ..< 5:
      let validMsg = RPCMsg(
        messages: @[Message(topic: topic, data: ("valid-message-" & $i).toBytes())]
      )
      nodes[1].broadcast(nodes[1].mesh[topic], validMsg, isHighPriority = true)

      let invalidMsg =
        RPCMsg(messages: @[Message(topic: topic, data: ("failed-sig-" & $i).toBytes())])
      nodes[2].broadcast(nodes[2].mesh[topic], invalidMsg, isHighPriority = true)

      let invalidMsg2 = RPCMsg(
        messages: @[Message(topic: topic, data: ("failed-custom-" & $i).toBytes())]
      )
      nodes[3].broadcast(nodes[3].mesh[topic], invalidMsg2, isHighPriority = true)

      await sleepAsync(1.milliseconds)

    # And messages are processed
    # Then invalidMessageDeliveries stats are applied
    checkUntilTimeout:
      messageCount == 15
      centerNode.getInvalidDeliveries(nodes[1], topic) == 0.0 # valid msgs
      centerNode.getInvalidDeliveries(nodes[2], topic) == 5.0 # invalid msgs
      centerNode.getInvalidDeliveries(nodes[3], topic) == 5.0 # invalid msgs
      centerNode.mesh[topic].toSeq().len == 3

    # When scoring hartbeat occurs
    # Then peer scores are calculated
    checkUntilTimeout:
      # node1: p1 (time in mesh) + p2 (first message deliveries)
      centerNode.getPeerScore(nodes[1], topic) > 5.0 and
        centerNode.getPeerScore(nodes[1], topic) < 6.0
      # node2: p1 (time in mesh) - p4 (invalid message deliveries)
      centerNode.getPeerScore(nodes[2], topic) < -249.0 and
        centerNode.getPeerScore(nodes[2], topic) > -250.0
      # node3: p1 (time in mesh) - p4 (invalid message deliveries)
      centerNode.getPeerScore(nodes[3], topic) < -249.0 and
        centerNode.getPeerScore(nodes[3], topic) > -250.0
      # all peers are still connected
      centerNode.mesh[topic].toSeq().len == 3

    # When disconnecting peers with bad score (score < graylistThreshold) is enabled
    for node in nodes:
      node.parameters.disconnectBadPeers = true

    # Then peers with bad score are disconnected on scoring heartbeat
    checkUntilTimeout:
      centerNode.mesh[topic].toSeq().len == 1

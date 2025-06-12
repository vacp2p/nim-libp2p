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
import ../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable, pubsubpeer]
import ../../libp2p/protocols/pubsub/rpc/[messages]
import ../../libp2p/muxers/muxer
import ../helpers
import ../utils/[futures]

suite "GossipSub Scoring":
  teardown:
    checkTrackers()

  asyncTest "Disconnect bad peers":
    let topic = "foobar"
    var (gossipSub, conns, peers) =
      setupGossipSubWithPeers(30, topic, populateGossipsub = true)
    defer:
      await teardownGossipSub(gossipSub, conns)

    gossipSub.parameters.disconnectBadPeers = true
    gossipSub.parameters.appSpecificWeight = 1.0

    for i, peer in peers:
      peer.appScore = gossipSub.parameters.graylistThreshold - 1
      let conn = conns[i]
      gossipSub.switch.connManager.storeMuxer(Muxer(connection: conn))

    gossipSub.updateScores()

    await sleepAsync(100.millis)

    check:
      # test our disconnect mechanics
      gossipSub.gossipsub.peers(topic) == 0
      # also ensure we cleanup properly the peersInIP table
      gossipSub.peersInIP.len == 0

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

  asyncTest "GossipThreshold - do not handle IHave if peer score is below threshold":
    let topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # Given peer with score below GossipThreshold
    gossipSub.parameters.gossipThreshold = -100.0
    let peer = peers[0]
    peer.score = -200.0

    # and IHave message
    let id = @[0'u8, 1, 2, 3]
    let msg = ControlIHave(topicID: topic, messageIDs: @[id])

    # When IHave is handled
    let iWant = gossipSub.handleIHave(peer, @[msg])

    # Then IHave is ignored
    check:
      iWant.messageIDs.len == 0

  asyncTest "GossipThreshold - do not handle IWant if peer score is below threshold":
    let topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # Given peer with score below GossipThreshold
    gossipSub.parameters.gossipThreshold = -100.0
    let peer = peers[0]
    peer.score = -200.0

    # and IWant message with MsgId in mcache and sentIHaves
    let id = @[0'u8, 1, 2, 3]
    gossipSub.mcache.put(id, Message())
    peer.sentIHaves[0].incl(id)
    let msg = ControlIWant(messageIDs: @[id])

    # When IWant is handled
    let messages = gossipSub.handleIWant(peer, @[msg])

    # Then IWant is ignored
    check:
      messages.len == 0

  asyncTest "GossipThreshold - do not trigger PeerExchange on Prune":
    let topic = "foobar"
    var (gossipSub, conns, peers) = setupGossipSubWithPeers(1, topic)
    defer:
      await teardownGossipSub(gossipSub, conns)

    # Given peer with score below GossipThreshold
    gossipSub.parameters.gossipThreshold = -100.0
    let peer = peers[0]
    peer.score = -200.0

    # and RoutingRecordsHandler added
    var routingRecordsFut = newFuture[void]()
    gossipSub.routingRecordsHandler.add(
      proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
        routingRecordsFut.complete()
    )

    # and Prune message
    let msg = ControlPrune(
      topicID: topic, peers: @[PeerInfoMsg(peerId: peer.peerId)], backoff: 123'u64
    )

    # When Prune is handled
    gossipSub.handlePrune(peer, @[msg])

    # Then handler is not triggered
    let result = await waitForState(routingRecordsFut, HEARTBEAT_TIMEOUT)
    check:
      result.isCancelled()

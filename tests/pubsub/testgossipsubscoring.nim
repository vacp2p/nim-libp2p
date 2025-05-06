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
import metrics
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, peertable, pubsubpeer]
import ../../libp2p/protocols/pubsub/rpc/[messages]
import ../../libp2p/muxers/muxer
import ../helpers, ../utils/[futures]

suite "GossipSub Scoring":
  teardown:
    checkTrackers()

  asyncTest "Disconnect bad peers":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    gossipSub.parameters.disconnectBadPeers = true
    gossipSub.parameters.appSpecificWeight = 1.0
    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      check false

    let topic = "foobar"
    var conns = newSeq[Connection]()
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      peer.handler = handler
      peer.appScore = gossipSub.parameters.graylistThreshold - 1
      gossipSub.gossipsub.mgetOrPut(topic, initHashSet[PubSubPeer]()).incl(peer)
      gossipSub.switch.connManager.storeMuxer(Muxer(connection: conn))

    gossipSub.updateScores()

    await sleepAsync(100.millis)

    check:
      # test our disconnect mechanics
      gossipSub.gossipsub.peers(topic) == 0
      # also ensure we cleanup properly the peersInIP table
      gossipSub.peersInIP.len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "flood publish to all peers with score above threshold, regardless of subscription":
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
    check (await nodes[0].publish(topic, message)) == 1
    await waitForHeartbeat(2)

    # Then only node 1 should receive the message
    let results = await waitForStates(@[handlerFut1, handlerFut2], HEARTBEAT_TIMEOUT)
    check:
      results[0].isCompleted(true)
      results[1].isPending()

  proc initializeGossipTest(): Future[(seq[PubSub], GossipSub, GossipSub)] {.async.} =
    let nodes =
      generateNodes(2, gossip = true, overheadRateLimit = Opt.some((20, 1.millis)))

    await startNodes(nodes)
    await connectNodesStar(nodes)

    proc handle(topic: string, data: seq[byte]) {.async.} =
      discard

    let gossip0 = GossipSub(nodes[0])
    let gossip1 = GossipSub(nodes[1])

    gossip0.subscribe("foobar", handle)
    gossip1.subscribe("foobar", handle)
    await waitSubGraph(nodes, "foobar")

    # Avoid being disconnected by failing signature verification
    gossip0.verifySignature = false
    gossip1.verifySignature = false

    return (nodes, gossip0, gossip1)

  proc currentRateLimitHits(): float64 =
    try:
      libp2p_gossipsub_peers_rate_limit_hits.valueByName(
        "libp2p_gossipsub_peers_rate_limit_hits_total", @["nim-libp2p"]
      )
    except KeyError:
      0

  asyncTest "e2e - GossipSub should not rate limit decodable messages below the size allowed":
    let rateLimitHits = currentRateLimitHits()
    let (nodes, gossip0, gossip1) = await initializeGossipTest()

    gossip0.broadcast(
      gossip0.mesh["foobar"],
      RPCMsg(messages: @[Message(topic: "foobar", data: newSeq[byte](10))]),
      isHighPriority = true,
    )
    await waitForHeartbeat()

    check currentRateLimitHits() == rateLimitHits
    check gossip1.switch.isConnected(gossip0.switch.peerInfo.peerId) == true

    # Disconnect peer when rate limiting is enabled
    gossip1.parameters.disconnectPeerAboveRateLimit = true
    gossip0.broadcast(
      gossip0.mesh["foobar"],
      RPCMsg(messages: @[Message(topic: "foobar", data: newSeq[byte](12))]),
      isHighPriority = true,
    )
    await waitForHeartbeat()

    check gossip1.switch.isConnected(gossip0.switch.peerInfo.peerId) == true
    check currentRateLimitHits() == rateLimitHits

    await stopNodes(nodes)

  asyncTest "e2e - GossipSub should rate limit undecodable messages above the size allowed":
    let rateLimitHits = currentRateLimitHits()

    let (nodes, gossip0, gossip1) = await initializeGossipTest()

    # Simulate sending an undecodable message
    await gossip1.peers[gossip0.switch.peerInfo.peerId].sendEncoded(
      newSeqWith(33, 1.byte), isHighPriority = true
    )
    await waitForHeartbeat()

    check currentRateLimitHits() == rateLimitHits + 1
    check gossip1.switch.isConnected(gossip0.switch.peerInfo.peerId) == true

    # Disconnect peer when rate limiting is enabled
    gossip1.parameters.disconnectPeerAboveRateLimit = true
    await gossip0.peers[gossip1.switch.peerInfo.peerId].sendEncoded(
      newSeqWith(35, 1.byte), isHighPriority = true
    )

    checkUntilTimeout gossip1.switch.isConnected(gossip0.switch.peerInfo.peerId) == false
    check currentRateLimitHits() == rateLimitHits + 2

    await stopNodes(nodes)

  asyncTest "e2e - GossipSub should rate limit decodable messages above the size allowed":
    let rateLimitHits = currentRateLimitHits()
    let (nodes, gossip0, gossip1) = await initializeGossipTest()

    let msg = RPCMsg(
      control: some(
        ControlMessage(
          prune:
            @[
              ControlPrune(
                topicID: "foobar",
                peers: @[PeerInfoMsg(peerId: PeerId(data: newSeq[byte](33)))],
                backoff: 123'u64,
              )
            ]
        )
      )
    )
    gossip0.broadcast(gossip0.mesh["foobar"], msg, isHighPriority = true)
    await waitForHeartbeat()

    check currentRateLimitHits() == rateLimitHits + 1
    check gossip1.switch.isConnected(gossip0.switch.peerInfo.peerId) == true

    # Disconnect peer when rate limiting is enabled
    gossip1.parameters.disconnectPeerAboveRateLimit = true
    let msg2 = RPCMsg(
      control: some(
        ControlMessage(
          prune:
            @[
              ControlPrune(
                topicID: "foobar",
                peers: @[PeerInfoMsg(peerId: PeerId(data: newSeq[byte](35)))],
                backoff: 123'u64,
              )
            ]
        )
      )
    )
    gossip0.broadcast(gossip0.mesh["foobar"], msg2, isHighPriority = true)

    checkUntilTimeout gossip1.switch.isConnected(gossip0.switch.peerInfo.peerId) == false
    check currentRateLimitHits() == rateLimitHits + 2

    await stopNodes(nodes)

  asyncTest "e2e - GossipSub should rate limit invalid messages above the size allowed":
    let rateLimitHits = currentRateLimitHits()
    let (nodes, gossip0, gossip1) = await initializeGossipTest()

    let topic = "foobar"
    proc execValidator(
        topic: string, message: messages.Message
    ): Future[ValidationResult] {.async: (raw: true).} =
      let res = newFuture[ValidationResult]()
      res.complete(ValidationResult.Reject)
      res

    gossip0.addValidator(topic, execValidator)
    gossip1.addValidator(topic, execValidator)

    let msg = RPCMsg(messages: @[Message(topic: topic, data: newSeq[byte](40))])

    gossip0.broadcast(gossip0.mesh[topic], msg, isHighPriority = true)
    await waitForHeartbeat()

    check currentRateLimitHits() == rateLimitHits + 1
    check gossip1.switch.isConnected(gossip0.switch.peerInfo.peerId) == true

    # Disconnect peer when rate limiting is enabled
    gossip1.parameters.disconnectPeerAboveRateLimit = true
    gossip0.broadcast(
      gossip0.mesh[topic],
      RPCMsg(messages: @[Message(topic: topic, data: newSeq[byte](35))]),
      isHighPriority = true,
    )

    checkUntilTimeout gossip1.switch.isConnected(gossip0.switch.peerInfo.peerId) == false
    check currentRateLimitHits() == rateLimitHits + 2

    await stopNodes(nodes)

  asyncTest "GossipSub directPeers: don't kick direct peer with low score":
    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)

    await GossipSub(nodes[0]).addDirectPeer(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )
    await GossipSub(nodes[1]).addDirectPeer(
      nodes[0].switch.peerInfo.peerId, nodes[0].switch.peerInfo.addrs
    )

    GossipSub(nodes[1]).parameters.disconnectBadPeers = true
    GossipSub(nodes[1]).parameters.graylistThreshold = 100000

    var handlerFut = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      handlerFut.complete()

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    tryPublish await nodes[0].publish("foobar", toBytes("hellow")), 1

    await handlerFut

    GossipSub(nodes[1]).updateScores()
    # peer shouldn't be in our mesh
    check:
      GossipSub(nodes[1]).peerStats[nodes[0].switch.peerInfo.peerId].score <
        GossipSub(nodes[1]).parameters.graylistThreshold
    GossipSub(nodes[1]).updateScores()

    handlerFut = newFuture[void]()
    tryPublish await nodes[0].publish("foobar", toBytes("hellow2")), 1

    # Without directPeers, this would fail
    await handlerFut.wait(1.seconds)

  asyncTest "GossipSub peers disconnections mechanics":
    var runs = 10

    let nodes = generateNodes(runs, gossip = true, triggerSelf = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    var seen: Table[string, int]
    var seenFut = newFuture[void]()
    for i in 0 ..< nodes.len:
      let dialer = nodes[i]
      var handler: TopicHandler
      closureScope:
        var peerName = $dialer.peerInfo.peerId
        handler = proc(topic: string, data: seq[byte]) {.async.} =
          seen.mgetOrPut(peerName, 0).inc()
          check topic == "foobar"
          if not seenFut.finished() and seen.len >= runs:
            seenFut.complete()

      dialer.subscribe("foobar", handler)

    await waitSubGraph(nodes, "foobar")

    # ensure peer stats are stored properly and kept properly
    check:
      GossipSub(nodes[0]).peerStats.len == runs - 1 # minus self

    tryPublish await wait(
      nodes[0].publish("foobar", toBytes("from node " & $nodes[0].peerInfo.peerId)),
      1.minutes,
    ), 1, 5.seconds, 3.minutes

    await wait(seenFut, 5.minutes)
    check:
      seen.len >= runs
    for k, v in seen.pairs:
      check:
        v >= 1

    for node in nodes:
      var gossip = GossipSub(node)
      check:
        "foobar" in gossip.gossipsub
        gossip.fanout.len == 0
        gossip.mesh["foobar"].len > 0

    # Removing some subscriptions

    for i in 0 ..< runs:
      if i mod 3 != 0:
        nodes[i].unsubscribeAll("foobar")

    # Waiting 2 heartbeats

    for _ in 0 .. 1:
      let evnt = newAsyncEvent()
      GossipSub(nodes[0]).heartbeatEvents &= evnt
      await evnt.wait()

    # ensure peer stats are stored properly and kept properly
    check:
      GossipSub(nodes[0]).peerStats.len == runs - 1 # minus self

    # Adding again subscriptions

    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"

    for i in 0 ..< runs:
      if i mod 3 != 0:
        nodes[i].subscribe("foobar", handler)

    # Waiting 2 heartbeats

    for _ in 0 .. 1:
      let evnt = newAsyncEvent()
      GossipSub(nodes[0]).heartbeatEvents &= evnt
      await evnt.wait()

    # ensure peer stats are stored properly and kept properly
    check:
      GossipSub(nodes[0]).peerStats.len == runs - 1 # minus self

  asyncTest "GossipSub scoring - decayInterval":
    let nodes = generateNodes(2, gossip = true)

    var gossip = GossipSub(nodes[0])
    const testDecayInterval = 50.milliseconds
    gossip.parameters.decayInterval = testDecayInterval

    startNodesAndDeferStop(nodes)

    var handlerFut = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      handlerFut.complete()

    await connectNodesStar(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    tryPublish await nodes[0].publish("foobar", toBytes("hello")), 1

    await handlerFut

    gossip.peerStats[nodes[1].peerInfo.peerId].topicInfos["foobar"].meshMessageDeliveries =
      100
    gossip.topicParams["foobar"].meshMessageDeliveriesDecay = 0.9

    # We should have decayed 5 times, though allowing 4..6
    await sleepAsync(testDecayInterval * 5)
    check:
      gossip.peerStats[nodes[1].peerInfo.peerId].topicInfos["foobar"].meshMessageDeliveries in
        50.0 .. 66.0

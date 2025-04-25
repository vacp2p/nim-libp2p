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
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, mcache]
import ../helpers

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

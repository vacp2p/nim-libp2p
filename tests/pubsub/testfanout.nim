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
import chronicles
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, peertable]
import ../../libp2p/protocols/pubsub/rpc/[messages]
import ../helpers

suite "GossipSub Fanout Management":
  teardown:
    checkTrackers()

  asyncTest "`replenishFanout` Degree Lo":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic = "foobar"
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()

    var conns = newSeq[Connection]()
    for i in 0 ..< 15:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      var peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.gossipsub[topic].incl(peer)

    check gossipSub.gossipsub[topic].len == 15
    gossipSub.replenishFanout(topic)
    check gossipSub.fanout[topic].len == gossipSub.parameters.d

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`dropFanoutPeers` drop expired fanout topics":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic = "foobar"
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.fanout[topic] = initHashSet[PubSubPeer]()
    gossipSub.lastFanoutPubSub[topic] = Moment.fromNow(1.millis)
    await sleepAsync(5.millis) # allow the topic to expire

    var conns = newSeq[Connection]()
    for i in 0 ..< 6:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = PeerId.init(PrivateKey.random(ECDSA, rng[]).get()).tryGet()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.fanout[topic].incl(peer)

    check gossipSub.fanout[topic].len == gossipSub.parameters.d

    gossipSub.dropFanoutPeers()
    check topic notin gossipSub.fanout

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "`dropFanoutPeers` leave unexpired fanout topics":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      discard

    let topic1 = "foobar1"
    let topic2 = "foobar2"
    gossipSub.topicParams[topic1] = TopicParams.init()
    gossipSub.topicParams[topic2] = TopicParams.init()
    gossipSub.fanout[topic1] = initHashSet[PubSubPeer]()
    gossipSub.fanout[topic2] = initHashSet[PubSubPeer]()
    gossipSub.lastFanoutPubSub[topic1] = Moment.fromNow(1.millis)
    gossipSub.lastFanoutPubSub[topic2] = Moment.fromNow(1.minutes)
    await sleepAsync(5.millis) # allow the topic to expire

    var conns = newSeq[Connection]()
    for i in 0 ..< 6:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler
      gossipSub.fanout[topic1].incl(peer)
      gossipSub.fanout[topic2].incl(peer)

    check gossipSub.fanout[topic1].len == gossipSub.parameters.d
    check gossipSub.fanout[topic2].len == gossipSub.parameters.d

    gossipSub.dropFanoutPeers()
    check topic1 notin gossipSub.fanout
    check topic2 in gossipSub.fanout

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "e2e - GossipSub send over fanout A -> B":
    var passed = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      passed.complete()

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")

    var observed = 0
    let
      obs1 = PubSubObserver(
        onRecv: proc(peer: PubSubPeer, msgs: var RPCMsg) =
          inc observed
      )
      obs2 = PubSubObserver(
        onSend: proc(peer: PubSubPeer, msgs: var RPCMsg) =
          inc observed
      )

    nodes[1].addObserver(obs1)
    nodes[0].addObserver(obs2)

    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    var gossip1: GossipSub = GossipSub(nodes[0])
    var gossip2: GossipSub = GossipSub(nodes[1])

    check:
      "foobar" in gossip1.gossipsub
      gossip1.fanout.hasPeerId("foobar", gossip2.peerInfo.peerId)
      not gossip1.mesh.hasPeerId("foobar", gossip2.peerInfo.peerId)

    await passed.wait(2.seconds)

    check observed == 2

  asyncTest "e2e - GossipSub send over fanout A -> B for subscribed topic":
    var passed = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      passed.complete()

    let nodes = generateNodes(2, gossip = true, unsubscribeBackoff = 10.minutes)

    startNodesAndDeferStop(nodes)

    GossipSub(nodes[1]).parameters.d = 0
    GossipSub(nodes[1]).parameters.dHigh = 0
    GossipSub(nodes[1]).parameters.dLow = 0

    await connectNodesStar(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    let gsNode = GossipSub(nodes[1])
    checkUntilTimeout:
      gsNode.mesh.getOrDefault("foobar").len == 0
      GossipSub(nodes[0]).mesh.getOrDefault("foobar").len == 0
      (
        GossipSub(nodes[0]).gossipsub.getOrDefault("foobar").len == 1 or
        GossipSub(nodes[0]).fanout.getOrDefault("foobar").len == 1
      )

    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check:
      GossipSub(nodes[0]).fanout.getOrDefault("foobar").len > 0
      GossipSub(nodes[0]).mesh.getOrDefault("foobar").len == 0

    await passed.wait(2.seconds)

    trace "test done, stopping..."

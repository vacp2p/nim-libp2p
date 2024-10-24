# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[options, deques, sequtils, enumerate, algorithm, sets]
import stew/byteutils
import ../../libp2p/builders
import ../../libp2p/errors
import ../../libp2p/crypto/crypto
import ../../libp2p/stream/bufferstream
import ../../libp2p/protocols/pubsub/[pubsub, gossipsub, mcache, mcache, peertable]
import ../../libp2p/protocols/pubsub/rpc/[message, messages]
import ../../libp2p/switch
import ../../libp2p/muxers/muxer
import ../../libp2p/protocols/pubsub/rpc/protobuf
import utils
import chronos
import chronicles
import ../helpers

proc noop(data: seq[byte]) {.async: (raises: [CancelledError, LPStreamError]).} =
  discard

proc voidTopicHandler(topic: string, data: seq[byte]) {.async.} =
  discard

const MsgIdSuccess = "msg id gen success"
let DURATION_TIMEOUT = 500.milliseconds

suite "GossipSub Topic Membership Tests":
  teardown:
    checkTrackers()

  # Addition of Designed Test cases for 6. Topic Membership Tests: https://www.notion.so/Gossipsub-651e02d4d7894bb2ac1e4edb55f3192d

  # Generalized setup function to initialize one or more topics
  proc setupGossipSub(
      topics: seq[string], numPeers: int
  ): (TestGossipSub, seq[Connection]) =
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    var conns = newSeq[Connection]()

    for topic in topics:
      gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
      gossipSub.topicParams[topic] = TopicParams.init()
      gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()

      for i in 0 ..< numPeers:
        let conn = TestBufferStream.new(noop)
        conns &= conn
        let peerId = randomPeerId()
        conn.peerId = peerId
        let peer = gossipSub.getPubSubPeer(peerId)
        peer.sendConn = conn
        gossipSub.gossipsub[topic].incl(peer)

    return (gossipSub, conns)

  # Wrapper function to initialize a single topic by converting it into a seq
  proc setupGossipSub(topic: string, numPeers: int): (TestGossipSub, seq[Connection]) =
    setupGossipSub(@[topic], numPeers)

  # Helper function to subscribe to topics
  proc subscribeToTopics(gossipSub: TestGossipSub, topics: seq[string]) =
    for topic in topics:
      gossipSub.subscribe(
        topic,
        proc(topic: string, data: seq[byte]): Future[void] {.async.} =
          discard
        ,
      )

  # Helper function to unsubscribe to topics
  proc unsubscribeFromTopics(gossipSub: TestGossipSub, topics: seq[string]) =
    for topic in topics:
      gossipSub.unsubscribeAll(topic)

  proc commonSubscribe(
      nodes: seq[TestGossipSub],
      topic: string,
      handler: proc(topic: string, data: seq[byte]) {.async.},
  ) =
    for node in nodes:
      node.subscribe(topic, handler)
    echo "Subscribed all nodes to the topic: ", topic

  proc commonUnsubscribe(
      nodes: seq[TestGossipSub],
      topic: string,
      handler: proc(topic: string, data: seq[byte]) {.async.},
  ) =
    for node in nodes:
      node.unsubscribe(topic, handler)
    echo "Unsubscribed all nodes from the topic: ", topic

  # Simulate the `SUBSCRIBE` to the topic and check proper handling in the mesh and gossipsub structures
  asyncTest "handle SUBSCRIBE to the topic":
    let topic = "test-topic"
    let (gossipSub, conns) = setupGossipSub(topic, 5)

    subscribeToTopics(gossipSub, @[topic])

    check gossipSub.topics.contains(topic)

    check gossipSub.gossipsub[topic].len() == 5

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # Simulate an UNSUBSCRIBE to the topic and check if the topic is removed from the relevant data structures but remains in gossipsub
  asyncTest "handle UNSUBSCRIBE to the topic":
    let topic = "test-topic"
    let (gossipSub, conns) = setupGossipSub(topic, 5)

    subscribeToTopics(gossipSub, @[topic])

    unsubscribeFromTopics(gossipSub, @[topic])

    check topic notin gossipSub.topics
    check topic notin gossipSub.mesh
    check topic in gossipSub.gossipsub

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # Test subscribing and unsubscribing multiple topics
  asyncTest "handle SUBSCRIBE and UNSUBSCRIBE multiple topics":
    let topics = ["topic1", "topic2", "topic3"].toSeq()
    let (gossipSub, conns) = setupGossipSub(topics, 5)

    subscribeToTopics(gossipSub, topics)

    check gossipSub.topics.len == 3
    for topic in topics:
      check gossipSub.gossipsub[topic].len() == 5

    unsubscribeFromTopics(gossipSub, topics)

    for topic in topics:
      check topic notin gossipSub.topics
      check topic notin gossipSub.mesh
      check topic in gossipSub.gossipsub

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # Test ensuring that the number of subscriptions does not exceed the limit set in the GossipSub parameters
  asyncTest "subscription limit test":
    let topicCount = 15
    let gossipSubParams = 10
    let topicNames = toSeq(mapIt(0 .. topicCount - 1, "topic" & $it))

    let (gossipSub, conns) = setupGossipSub(topicNames, 0)

    gossipSub.topicsHigh = gossipSubParams

    for topic in topicNames:
      if gossipSub.topics.len < gossipSub.topicsHigh:
        gossipSub.subscribe(
          topic,
          proc(topic: string, data: seq[byte]): Future[void] {.async.} =
            discard
          ,
        )
      else:
        check gossipSub.topics.len == gossipSub.topicsHigh

    check gossipSub.topics.len <= gossipSub.topicsHigh
    check gossipSub.topics.len == gossipSub.topicsHigh

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # Test for verifying peers joining a topic using `JOIN(topic)`
  asyncTest "handle JOIN topic and mesh is updated":
    let topic = "test-join-topic"

    let (gossipSub, conns) = setupGossipSub(topic, 5)

    commonSubscribe(@[gossipSub], topic, voidTopicHandler)

    check gossipSub.mesh[topic].len == 5
    check gossipSub.topics.contains(topic)

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # Test the behavior when multiple peers join and leave a topic simultaneously.
  asyncTest "multiple peers join and leave topic simultaneously":
    let
      numberOfNodes = 6
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)
      nodesFut = await allFinished(nodes.mapIt(it.switch.start()))

    await subscribeNodes(nodes)
    for node in nodes:
      node.subscribe(topic, voidTopicHandler)

    await sleepAsync(2 * DURATION_TIMEOUT)

    for i in 0 ..< numberOfNodes:
      let currentGossip = GossipSub(nodes[i])
      check currentGossip.gossipsub.hasKey(topic)

    for i in 0 ..< numberOfNodes:
      let currentGossip = GossipSub(nodes[i])

    for x in 0 ..< numberOfNodes:
      for y in 0 ..< numberOfNodes:
        if x != y:
          await waitSub(nodes[x], nodes[y], topic)

    await sleepAsync(2 * DURATION_TIMEOUT)

    let expectedNumberOfPeers = numberOfNodes - 1
    for i in 0 ..< numberOfNodes:
      let currentGossip = GossipSub(nodes[i])
      check:
        currentGossip.gossipsub[topic].len == expectedNumberOfPeers
        currentGossip.mesh[topic].len == expectedNumberOfPeers
        currentGossip.fanout.len == 0

    let firstNodeGossip = GossipSub(nodes[0])
    let peersToUnsubscribe = firstNodeGossip.mesh[topic].toSeq()[0 .. 2]
    let peerIdsToUnsubscribe = peersToUnsubscribe.mapIt(it.peerId)
    for node in nodes:
      for peerId in peerIdsToUnsubscribe:
        node.unsubscribe(topic, voidTopicHandler)
        node.peers.del(peerId)

    await sleepAsync(3 * DURATION_TIMEOUT)

    check firstNodeGossip.mesh.getOrDefault(topic).len == 3

    for peer in peersToUnsubscribe:
      check not firstNodeGossip.mesh[topic].contains(peer)

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

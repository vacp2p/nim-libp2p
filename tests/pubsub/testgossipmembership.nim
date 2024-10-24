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

  # Simulate the `SUBSCRIBE` to the topic and check proper handling in the mesh and gossipsub structures
  asyncTest "handle SUBSCRIBE to the topic":
    let
      numberOfNodes = 5
      topic = "test-topic"
      nodes = generateNodes(numberOfNodes, gossip = true)

    await allFuturesThrowing(nodes.mapIt(it.switch.start()))

    await subscribeNodes(nodes)
    for node in nodes:
      node.subscribe(topic, voidTopicHandler)

    await sleepAsync(2 * DURATION_TIMEOUT)

    for node in nodes:
      let currentGossip = GossipSub(node)

      check currentGossip.topics.contains(topic)
      check currentGossip.gossipsub[topic].len() == numberOfNodes - 1
      check currentGossip.mesh[topic].len() == numberOfNodes - 1

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

  # Simulate an UNSUBSCRIBE to the topic and check if the topic is removed from all relevant data structures
  asyncTest "handle UNSUBSCRIBE to the topic":
    let
      numberOfNodes = 5
      topic = "test-topic"
      nodes = generateNodes(numberOfNodes, gossip = true)

    await allFuturesThrowing(nodes.mapIt(it.switch.start()))

    await subscribeNodes(nodes)
    for node in nodes:
      node.subscribe(topic, voidTopicHandler)

    await sleepAsync(2 * DURATION_TIMEOUT)

    for node in nodes:
      node.unsubscribe(topic, voidTopicHandler)

    await sleepAsync(2 * DURATION_TIMEOUT)

    for node in nodes:
      let currentGossip = GossipSub(node)

      check topic notin currentGossip.topics

      if topic in currentGossip.mesh:
        check currentGossip.mesh[topic].len == 0
      else:
        check topic notin currentGossip.mesh

      if topic in currentGossip.gossipsub:
        check currentGossip.gossipsub[topic].len == 0
      else:
        check topic notin currentGossip.gossipsub

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

  # Test subscribing and unsubscribing multiple topics
  asyncTest "handle SUBSCRIBE and UNSUBSCRIBE multiple topics":
    let
      numberOfNodes = 5
      topics = ["topic1", "topic2", "topic3"].toSeq()
      nodes = generateNodes(numberOfNodes, gossip = true)

    await allFuturesThrowing(nodes.mapIt(it.switch.start()))

    await subscribeNodes(nodes)
    for node in nodes:
      for topic in topics:
        node.subscribe(topic, voidTopicHandler)

    await sleepAsync(2 * DURATION_TIMEOUT)

    for node in nodes:
      let currentGossip = GossipSub(node)
      check currentGossip.topics.len == topics.len
      for topic in topics:
        check currentGossip.gossipsub[topic].len == numberOfNodes - 1

    for node in nodes:
      for topic in topics:
        node.unsubscribe(topic, voidTopicHandler)

    await sleepAsync(2 * DURATION_TIMEOUT)

    for node in nodes:
      let currentGossip = GossipSub(node)
      for topic in topics:
        check topic notin currentGossip.topics
        check topic notin currentGossip.mesh
        check topic notin currentGossip.gossipsub

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

  # Test ensuring that the number of subscriptions does not exceed the limit set in the GossipSub parameters
  asyncTest "subscription limit test":
    let
      topicCount = 15
      gossipSubParams = 10
      topicNames = toSeq(mapIt(0 .. topicCount - 1, "topic" & $it))
      numberOfNodes = 1
      nodes = generateNodes(numberOfNodes, gossip = true)

    await allFuturesThrowing(nodes.mapIt(it.switch.start()))

    let gossipSub = GossipSub(nodes[0])
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

    check gossipSub.topics.len == gossipSub.topicsHigh

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

  # Test for verifying peers joining a topic using `JOIN(topic)`
  asyncTest "handle JOIN topic and mesh is updated":
    let
      topic = "test-join-topic"
      numberOfNodes = 5
      nodes = generateNodes(numberOfNodes, gossip = true)

    await allFuturesThrowing(nodes.mapIt(it.switch.start()))

    await subscribeNodes(nodes)
    for node in nodes:
      node.subscribe(topic, voidTopicHandler)

    await sleepAsync(2 * DURATION_TIMEOUT)

    for node in nodes:
      let currentGossip = GossipSub(node)
      check currentGossip.mesh[topic].len == numberOfNodes - 1
      check currentGossip.topics.contains(topic)

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

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
      check currentGossip.mesh.hasKey(topic)
      check currentGossip.topics.contains(topic)

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
    let peersToUnsubscribe = nodes[1 ..< 3]
    for peer in peersToUnsubscribe:
      peer.unsubscribe(topic, voidTopicHandler)

    await sleepAsync(3 * DURATION_TIMEOUT)

    check firstNodeGossip.mesh.getOrDefault(topic).len == 3
    check firstNodeGossip.gossipsub[topic].len == 3
    check topic in firstNodeGossip.topics

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

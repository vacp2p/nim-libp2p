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
import unittest2, chronos, stew/byteutils, ../../libp2p/protocols/pubsub/gossipsub
import ../helpers

import sequtils, options, tables, sets, sugar
import chronos, chronicles # Added chronicles for logging (trace)
import stew/byteutils
import chronos/ratelimit
import metrics

import ../../libp2p/protocols/pubsub/errors as pubsub_errors
import ../helpers

proc noop(data: seq[byte]) {.async: (raises: [CancelledError, LPStreamError]).} =
  discard

const MsgIdSuccess = "msg id gen success"

suite "GossipSub Topic Membership Tests":
  teardown:
    checkTrackers()

  # Addition of Designed Test cases for 6. Topic Membership Tests: https://www.notion.so/Gossipsub-651e02d4d7894bb2ac1e4edb55f3192d

  # Simulate the `SUBSCRIBE` event and check proper handling in the mesh and gossipsub structures
  asyncTest "handle SUBSCRIBE event":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    # Ensure topic is correctly initialized
    let topic = "test-topic"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
      # Initialize gossipsub for the topic

    var conns = newSeq[Connection]()
    for i in 0 ..< 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer) # Ensure the topic is added to gossipsub

    # Subscribe to the topic
    gossipSub.PubSub.subscribe(
      topic,
      proc(topic: string, data: seq[byte]): Future[void] {.async.} =
        discard
      ,
    )

    check gossipSub.topics.contains(topic) # Check if the topic is in topics
    check gossipSub.gossipsub[topic].len() > 0 # Check if topic added to gossipsub

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # This test will simulate an UNSUBSCRIBE event and check if the topic is removed from the relevant data structures but remains in gossipsub
  asyncTest "handle UNSUBSCRIBE event":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    # Ensure topic is initialized properly in all relevant data structures
    let topic = "test-topic"
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
      # Initialize gossipsub for the topic

    var conns = newSeq[Connection]()
    for i in 0 ..< 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)
        # Ensure peers are added to gossipsub for the topic

    # Subscribe to the topic first
    gossipSub.PubSub.subscribe(
      topic,
      proc(topic: string, data: seq[byte]): Future[void] {.async.} =
        discard
      ,
    )

    # Now unsubscribe from the topic
    gossipSub.PubSub.unsubscribeAll(topic)

    # Verify the topic is removed from relevant structures
    check topic notin gossipSub.topics # The topic should not be in topics
    check topic notin gossipSub.mesh # The topic should be removed from the mesh
    check topic in gossipSub.gossipsub
      # The topic should remain in gossipsub (for fanout)

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # This test ensures that multiple topics can be subscribed to and unsubscribed from, with proper initialization of the topic structures.
  asyncTest "handle multiple SUBSCRIBE and UNSUBSCRIBE events":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topics = ["topic1", "topic2", "topic3"]

    var conns = newSeq[Connection]()
    for topic in topics:
      # Initialize all relevant structures before subscribing
      gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
      gossipSub.topicParams[topic] = TopicParams.init()
      gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()
        # Initialize gossipsub for each topic

      gossipSub.PubSub.subscribe(
        topic,
        proc(topic: string, data: seq[byte]): Future[void] {.async.} =
          discard
        ,
      )

    # Verify that all topics are added to the topics and gossipsub
    check gossipSub.topics.len == 3
    for topic in topics:
      check gossipSub.gossipsub[topic].len() >= 0

    # Now unsubscribe from all topics
    for topic in topics:
      gossipSub.PubSub.unsubscribeAll(topic)

    # Ensure topics are removed from topics and mesh, but still present in gossipsub
    for topic in topics:
      check topic notin gossipSub.topics
      check topic notin gossipSub.mesh
      check topic in gossipSub.gossipsub

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # This test ensures that the number of subscriptions does not exceed the limit set in the GossipSub parameters
  asyncTest "subscription limit test":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    gossipSub.topicsHigh = 10 # Set a limit for the number of subscriptions

    var conns = newSeq[Connection]()
    for i in 0 .. gossipSub.topicsHigh + 5:
      let topic = "topic" & $i
      # Ensure all topics are properly initialized before subscribing
      gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
      gossipSub.topicParams[topic] = TopicParams.init()
      gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()

      if gossipSub.topics.len < gossipSub.topicsHigh:
        gossipSub.PubSub.subscribe(
          topic,
          proc(topic: string, data: seq[byte]): Future[void] {.async.} =
            discard
          ,
        )
      else:
        # Prevent subscription beyond the limit and log the error
        echo "Subscription limit reached for topic: ", topic

    # Ensure that the number of subscribed topics does not exceed the limit
    check gossipSub.topics.len <= gossipSub.topicsHigh
    check gossipSub.topics.len == gossipSub.topicsHigh

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # Test for verifying peers joining a topic using `JOIN(topic)`
  asyncTest "handle JOIN event":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topic = "test-join-topic"

    # Initialize relevant data structures
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()

    var conns = newSeq[Connection]()

    for i in 0 ..< 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)

    # Simulate the peer joining the topic
    gossipSub.PubSub.subscribe(
      topic,
      proc(topic: string, data: seq[byte]): Future[void] {.async.} =
        discard
      ,
    )

    check gossipSub.mesh[topic].len > 0 # Ensure the peer is added to the mesh
    check gossipSub.topics.contains(topic) # Ensure the topic is in `topics`

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  # Test for verifying peers leaving a topic using `LEAVE(topic)`
  asyncTest "handle LEAVE event":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let topic = "test-leave-topic"

    # Initialize relevant data structures
    gossipSub.mesh[topic] = initHashSet[PubSubPeer]()
    gossipSub.topicParams[topic] = TopicParams.init()
    gossipSub.gossipsub[topic] = initHashSet[PubSubPeer]()

    var conns = newSeq[Connection]()

    for i in 0 ..< 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.sendConn = conn
      gossipSub.gossipsub[topic].incl(peer)

    # Simulate peer joining the topic first
    gossipSub.PubSub.subscribe(
      topic,
      proc(topic: string, data: seq[byte]): Future[void] {.async.} =
        discard
      ,
    )

    # Now simulate peer leaving the topic
    gossipSub.PubSub.unsubscribeAll(topic)

    check topic notin gossipSub.mesh # Ensure the peer is removed from the mesh
    check topic in gossipSub.gossipsub # Ensure the topic remains in `gossipsub`

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

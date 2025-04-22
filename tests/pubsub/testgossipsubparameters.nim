# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import sequtils, tables, sets, sugar
import chronos, stew/byteutils
import chronicles
import metrics
import
  utils,
  ../../libp2p/[
    protocols/pubsub/pubsub,
    protocols/pubsub/gossipsub,
    protocols/pubsub/peertable,
    protocols/pubsub/rpc/messages,
  ]
import ../helpers, ../utils/[futures]
from ../../libp2p/protocols/pubsub/mcache import window

proc voidTopicHandler(topic: string, data: seq[byte]) {.async.} =
  discard

proc createCompleteHandler(): (
  Future[bool], proc(topic: string, data: seq[byte]) {.async.}
) =
  var fut = newFuture[bool]()
  proc handler(topic: string, data: seq[byte]) {.async.} =
    fut.complete(true)

  return (fut, handler)

proc addIHaveObservers(nodes: seq[auto], topic: string, receivedIHaves: ref seq[int]) =
  let numberOfNodes = nodes.len
  receivedIHaves[] = repeat(0, numberOfNodes)

  for i in 0 ..< numberOfNodes:
    var pubsubObserver: PubSubObserver
    capture i:
      let checkForIhaves = proc(peer: PubSubPeer, msgs: var RPCMsg) =
        if msgs.control.isSome:
          let iHave = msgs.control.get.ihave
          if iHave.len > 0:
            for msg in iHave:
              if msg.topicID == topic:
                receivedIHaves[i] += 1
      pubsubObserver = PubSubObserver(onRecv: checkForIhaves)
    nodes[i].addObserver(pubsubObserver)

proc addIDontWantObservers(nodes: seq[auto], receivedIDontWants: ref seq[int]) =
  let numberOfNodes = nodes.len
  receivedIDontWants[] = repeat(0, numberOfNodes)

  for i in 0 ..< numberOfNodes:
    var pubsubObserver: PubSubObserver
    capture i:
      let checkForIDontWant = proc(peer: PubSubPeer, msgs: var RPCMsg) =
        if msgs.control.isSome:
          let iDontWant = msgs.control.get.idontwant
          if iDontWant.len > 0:
            receivedIDontWants[i] += 1
      pubsubObserver = PubSubObserver(onRecv: checkForIDontWant)
    nodes[i].addObserver(pubsubObserver)

suite "Gossipsub Parameters":
  teardown:
    checkTrackers()

  asyncTest "dont prune peers if mesh len is less than d_high":
    let
      numberOfNodes = 5
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitSubAllNodes(nodes, topic)

    let expectedNumberOfPeers = numberOfNodes - 1
    for i in 0 ..< numberOfNodes:
      var gossip = GossipSub(nodes[i])
      check:
        gossip.gossipsub[topic].len == expectedNumberOfPeers
        gossip.mesh[topic].len == expectedNumberOfPeers
        gossip.fanout.len == 0

  asyncTest "prune peers if mesh len is higher than d_high":
    let
      numberofNodes = 15
      topic = "foobar"
      nodes = generateNodes(numberofNodes, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitSubAllNodes(nodes, topic)

    # Give it time for a heartbeat
    await waitForHeartbeat()

    let
      expectedNumberOfPeers = numberofNodes - 1
      dHigh = 12
      d = 6
      dLow = 4

    for i in 0 ..< numberofNodes:
      var gossip = GossipSub(nodes[i])

      check:
        gossip.gossipsub[topic].len == expectedNumberOfPeers
        gossip.mesh[topic].len >= dLow and gossip.mesh[topic].len <= dHigh
        gossip.fanout.len == 0

  asyncTest "messages sent to peers not in the mesh are propagated via gossip":
    let
      numberOfNodes = 5
      topic = "foobar"
      dValues = DValues(dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1))
      nodes = generateNodes(numberOfNodes, gossip = true, dValues = some(dValues))

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iHave messages
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

    # And are interconnected
    await connectNodesStar(nodes)

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # When node 0 sends a message
    check (await nodes[0].publish(topic, "Hello!".toBytes())) > 0
    await waitForHeartbeat()

    # At least one of the nodes should have received an iHave message
    # The check is made this way because the mesh structure changes from run to run
    let receivedIHaves = receivedIHavesRef[]
    check:
      anyIt(receivedIHavesRef[], it > 0)

  asyncTest "messages are not sent back to source or forwarding peer":
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)

    startNodesAndDeferStop(nodes)

    let (handlerFut0, handler0) = createCompleteHandler()
    let (handlerFut1, handler1) = createCompleteHandler()
    let (handlerFut2, handler2) = createCompleteHandler()

    # Nodes are connected in a ring
    await connectNodes(nodes[0], nodes[1])
    await connectNodes(nodes[1], nodes[2])
    await connectNodes(nodes[2], nodes[0])

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, @[handler0, handler1, handler2])
    await waitForHeartbeat()

    # When node 0 sends a message
    check (await nodes[0].publish(topic, "Hello!".toBytes())) == 2
    await waitForHeartbeat()

    # Nodes 1 and 2 should receive the message, but node 0 shouldn't receive it back
    let results = await waitForStates(
      @[handlerFut0, handlerFut1, handlerFut2], WAIT_FOR_HEARTBEAT_TIMEOUT
    )
    check:
      results[0].isPending()
      results[1].isCompleted()
      results[2].isCompleted()

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
    await sleepAsync(1.seconds)

    # Given node 2's score is below the threshold
    for peer in g0.gossipsub.getOrDefault(topic):
      if peer.peerId == nodes[2].peerInfo.peerId:
        peer.score = (g0.parameters.publishThreshold - 1)

    # When node 0 publishes a message to topic "foo"
    let message = "Hello!".toBytes()
    check (await nodes[0].publish(topic, message)) == 1
    await sleepAsync(3.seconds)

    # Then only node 1 should receive the message
    let results =
      await waitForStates(@[handlerFut1, handlerFut2], WAIT_FOR_HEARTBEAT_TIMEOUT)
    check:
      results[0].isCompleted(true)
      results[1].isPending()

  asyncTest "adaptive gossip dissemination, dLazy and gossipFactor to 0":
    let
      numberOfNodes = 20
      topic = "foobar"
      dValues = DValues(
        dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1), dLazy: some(0)
      )
      nodes = generateNodes(
        numberOfNodes,
        gossip = true,
        dValues = some(dValues),
        gossipFactor = some(0.float),
      )

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iHave messages
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

    # And are connected to node 0
    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # When node 0 sends a message
    check (await nodes[0].publish(topic, "Hello!".toBytes())) == 3
    await waitForHeartbeat()

    # None of the nodes should have received an iHave message
    let receivedIHaves = receivedIHavesRef[]
    check:
      filterIt(receivedIHaves, it > 0).len == 0

  asyncTest "adaptive gossip dissemination, with gossipFactor priority":
    let
      numberOfNodes = 20
      topic = "foobar"
      dValues = DValues(
        dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1), dLazy: some(4)
      )
      nodes = generateNodes(
        numberOfNodes, gossip = true, dValues = some(dValues), gossipFactor = some(0.5)
      )

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iHave messages
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

    # And are connected to node 0
    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # When node 0 sends a message
    check (await nodes[0].publish(topic, "Hello!".toBytes())) == 3
    await waitForHeartbeat()

    # At least 8 of the nodes should have received an iHave message
    # That's because the gossip factor is 0.5 over 16 available nodes
    let receivedIHaves = receivedIHavesRef[]
    check:
      filterIt(receivedIHaves, it > 0).len >= 8

  asyncTest "adaptive gossip dissemination, with dLazy priority":
    let
      numberOfNodes = 20
      topic = "foobar"
      dValues = DValues(
        dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1), dLazy: some(6)
      )
      nodes = generateNodes(
        numberOfNodes,
        gossip = true,
        dValues = some(dValues),
        gossipFactor = some(0.float),
      )

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iHave messages
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

    # And are connected to node 0
    for i in 1 ..< numberOfNodes:
      await connectNodes(nodes[0], nodes[i])

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # When node 0 sends a message
    check (await nodes[0].publish(topic, "Hello!".toBytes())) == 3
    await waitForHeartbeat()

    # At least 6 of the nodes should have received an iHave message
    # That's because the dLazy is 6
    let receivedIHaves = receivedIHavesRef[]
    check:
      filterIt(receivedIHaves, it > 0).len == dValues.dLazy.get()

  asyncTest "iDontWant messages are broadcast immediately after receiving the first message instance":
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)

    startNodesAndDeferStop(nodes)

    # All nodes are checking for iDontWant messages
    var receivedIDontWantsRef = new seq[int]
    addIDontWantObservers(nodes, receivedIDontWantsRef)

    # And are connected in a line
    await connectNodes(nodes[0], nodes[1])
    await connectNodes(nodes[1], nodes[2])

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    # When node 0 sends a large message
    let largeMsg = newSeq[byte](1000)
    check (await nodes[0].publish(topic, largeMsg)) == 1
    await waitForHeartbeat()

    # Only node 2 should have received the iDontWant message
    let receivedIDontWants = receivedIDontWantsRef[]
    check:
      receivedIDontWants[0] == 0
      receivedIDontWants[1] == 0
      receivedIDontWants[2] == 1

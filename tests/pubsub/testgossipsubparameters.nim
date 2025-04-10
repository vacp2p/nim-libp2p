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

    await startNodes(nodes)
    await connectNodesStar(nodes)

    for node in nodes:
      node.subscribe(topic, voidTopicHandler)
    await waitSubAllNodes(nodes, topic)

    let expectedNumberOfPeers = numberOfNodes - 1
    for i in 0 ..< numberOfNodes:
      var gossip = GossipSub(nodes[i])
      check:
        gossip.gossipsub[topic].len == expectedNumberOfPeers
        gossip.mesh[topic].len == expectedNumberOfPeers
        gossip.fanout.len == 0

    await stopNodes(nodes)

  asyncTest "prune peers if mesh len is higher than d_high":
    let
      numberofNodes = 15
      topic = "foobar"
      nodes = generateNodes(numberofNodes, gossip = true)

    await startNodes(nodes)
    await connectNodesStar(nodes)

    for node in nodes:
      node.subscribe(topic, voidTopicHandler)
    await waitSubAllNodes(nodes, topic)

    # Give it time for a heartbeat
    await sleepAsync(DURATION_TIMEOUT)

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

    await stopNodes(nodes)

  asyncTest "messages sent to peers not in the mesh are propagated via gossip":
    # Given 5 nodes
    let
      numberOfNodes = 5
      topic = "foobar"
      dValues = DValues(dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1))
      nodes = generateNodes(numberOfNodes, gossip = true, dValues = some(dValues))

    await startNodes(nodes)

    # All of them are checking for iHave messages
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

    # All of them are interconnected
    await connectNodesStar(nodes)

    # And subscribed to the same topic
    for node in nodes:
      node.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    # When node 0 sends a message
    discard nodes[0].publish(topic, "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # At least one of the nodes should have received an iHave message
    # The check is made this way because the mesh structure changes from run to run
    let receivedIHaves = receivedIHavesRef[]
    check:
      anyIt(receivedIHavesRef[], it > 0)

    await stopNodes(nodes)

  asyncTest "messages are not sent back to source or forwarding peer":
    # Instantiate 3 nodes
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)
      node0 = nodes[0]
      node1 = nodes[1]
      node2 = nodes[2]

    await startNodes(nodes)

    # Each node with a handler
    let (handlerFut0, handler0) = createCompleteHandler()
    let (handlerFut1, handler1) = createCompleteHandler()
    let (handlerFut2, handler2) = createCompleteHandler()

    # Connect them in a ring
    await node0.switch.connect(node1.peerInfo.peerId, node1.peerInfo.addrs)
    await node1.switch.connect(node2.peerInfo.peerId, node2.peerInfo.addrs)
    await node2.switch.connect(node0.peerInfo.peerId, node0.peerInfo.addrs)
    await sleepAsync(DURATION_TIMEOUT)

    # Subscribe them all to the same topic
    nodes[0].subscribe(topic, handler0)
    nodes[1].subscribe(topic, handler1)
    nodes[2].subscribe(topic, handler2)
    await sleepAsync(DURATION_TIMEOUT)

    # When node 0 sends a message
    discard nodes[0].publish(topic, "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # Nodes 1 and 2 should receive the message, but node 0 shouldn't receive it back
    let results = await waitForResults(@[handlerFut0, handlerFut1, handlerFut2])
    check:
      results[0].isErr
      results[1].isOk
      results[2].isOk

    await stopNodes(nodes)

  asyncTest "flood publish to all peers with score above threshold, regardless of subscription":
    # Given 3 nodes
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true, floodPublish = true)
      g0 = GossipSub(nodes[0])

    await startNodes(nodes)

    # Nodes 1 and 2 are connected to node 0
    await nodes[0].switch.connect(nodes[1].peerInfo.peerId, nodes[1].peerInfo.addrs)
    await nodes[0].switch.connect(nodes[2].peerInfo.peerId, nodes[2].peerInfo.addrs)

    # Given 2 handlers
    let (handlerFut0, handler0) = createCompleteHandler()
    let (handlerFut1, handler1) = createCompleteHandler()

    # Nodes are subscribed to the same topic
    nodes[1].subscribe(topic, handler0)
    nodes[2].subscribe(topic, handler1)
    await sleepAsync(1.seconds)

    # Given node 2's score is below the threshold
    for peer in g0.gossipsub.getOrDefault(topic):
      if peer.peerId == nodes[2].peerInfo.peerId:
        peer.score = (g0.parameters.publishThreshold - 1)

    # When node 0 publishes a message to topic "foo"
    let message = "Hello!".toBytes()
    check (await nodes[0].publish(topic, message)) > 0
    await sleepAsync(3.seconds)

    # Then only node 1 should receive the message
    let results = await waitForResults(@[handlerFut0, handlerFut1])
    check:
      results[0].isOk and results[0].get == true
      results[1].isErr

    # Cleanup
    await stopNodes(nodes)

  asyncTest "adaptive gossip dissemination, dLazy and gossipFactor to 0":
    # Given 20 nodes
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

    await startNodes(nodes)

    # All of them are checking for iHave messages
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

    # All of them are connected to node 0
    for i in 1 ..< numberOfNodes:
      await nodes[0].switch.connect(nodes[i].peerInfo.peerId, nodes[i].peerInfo.addrs)

    # And subscribed to the same topic
    for node in nodes:
      node.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    # When node 0 sends a message
    discard nodes[0].publish(topic, "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # None of the nodes should have received an iHave message
    let receivedIHaves = receivedIHavesRef[]
    check:
      filterIt(receivedIHaves, it > 0).len == 0

    await stopNodes(nodes)

  asyncTest "adaptive gossip dissemination, with gossipFactor priority":
    # Given 20 nodes
    let
      numberOfNodes = 20
      topic = "foobar"
      dValues = DValues(
        dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1), dLazy: some(4)
      )
      nodes = generateNodes(
        numberOfNodes, gossip = true, dValues = some(dValues), gossipFactor = some(0.5)
      )

    await startNodes(nodes)

    # All of them are checking for iHave messages
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

    # All of them are connected to node 0
    for i in 1 ..< numberOfNodes:
      await nodes[0].switch.connect(nodes[i].peerInfo.peerId, nodes[i].peerInfo.addrs)

    # And subscribed to the same topic
    for node in nodes:
      node.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    # When node 0 sends a message
    discard nodes[0].publish(topic, "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # At least 8 of the nodes should have received an iHave message
    # That's because the gossip factor is 0.5 over 16 available nodes
    let receivedIHaves = receivedIHavesRef[]
    check:
      filterIt(receivedIHaves, it > 0).len >= 8

    await stopNodes(nodes)

  asyncTest "adaptive gossip dissemination, with dLazy priority":
    # Given 20 nodes
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

    await startNodes(nodes)

    # All of them are checking for iHave messages
    var receivedIHavesRef = new seq[int]
    addIHaveObservers(nodes, topic, receivedIHavesRef)

    # All of them are connected to node 0
    for i in 1 ..< numberOfNodes:
      await nodes[0].switch.connect(nodes[i].peerInfo.peerId, nodes[i].peerInfo.addrs)

    # And subscribed to the same topic
    for node in nodes:
      node.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    # When node 0 sends a message
    discard nodes[0].publish(topic, "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # At least 6 of the nodes should have received an iHave message
    # That's because the dLazy is 6
    let receivedIHaves = receivedIHavesRef[]
    check:
      filterIt(receivedIHaves, it > 0).len == dValues.dLazy.get()

    await stopNodes(nodes)

  asyncTest "iDontWant messages are broadcast immediately after receiving the first message instance":
    # Given 3 nodes
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)

    await startNodes(nodes)

    # And with iDontWant observers
    var receivedIDontWantsRef = new seq[int]
    addIDontWantObservers(nodes, receivedIDontWantsRef)

    # Connect them in a line
    await nodes[0].switch.connect(nodes[1].peerInfo.peerId, nodes[1].peerInfo.addrs)
    await nodes[1].switch.connect(nodes[2].peerInfo.peerId, nodes[2].peerInfo.addrs)
    await sleepAsync(DURATION_TIMEOUT)

    # Subscribe them all to the same topic
    nodes[0].subscribe(topic, voidTopicHandler)
    nodes[1].subscribe(topic, voidTopicHandler)
    nodes[2].subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    # When node 0 sends a large message
    let largeMsg = newSeq[byte](1000)
    discard nodes[0].publish(topic, largeMsg)
    await sleepAsync(DURATION_TIMEOUT)

    # Only node 2 should have received the iDontWant message
    let receivedIDontWants = receivedIDontWantsRef[]
    check:
      receivedIDontWants[0] == 0
      receivedIDontWants[1] == 0
      receivedIDontWants[2] == 1

    await stopNodes(nodes)

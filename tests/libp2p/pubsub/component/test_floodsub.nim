# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import sequtils, tables, sets, chronos, stew/byteutils
import
  ../utils,
  ../../../../libp2p/[
    switch,
    stream/connection,
    protocols/pubsub/pubsub,
    protocols/pubsub/floodsub,
    protocols/pubsub/rpc/messages,
    protocols/pubsub/peertable,
    protocols/pubsub/pubsubpeer,
  ]
import ../../../../libp2p/protocols/pubsub/errors as pubsub_errors
import ../../../tools/[unittest, futures]

suite "FloodSub Component":
  teardown:
    checkTrackers()

  asyncTest "FloodSub basic publish/subscribe A -> B":
    const topic = "foobar"
    let (handlerFut, handler) = createCompleteHandler()

    let nodes = generateNodes(2).toFloodSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, handler)
    waitSubscribe(nodes[0], nodes[1], topic)

    check (await nodes[0].publish(topic, "Hello!".toBytes())) > 0
    check (await handlerFut.wait(5.seconds)) == true

    when defined(libp2p_agents_metrics):
      let
        agentA = nodes[0].peers[nodes[1].switch.peerInfo.peerId].shortAgent
        agentB = nodes[1].peers[nodes[0].switch.peerInfo.peerId].shortAgent
      check:
        agentA == "nim-libp2p"
        agentB == "nim-libp2p"

  asyncTest "FloodSub basic publish/subscribe B -> A":
    const topic = "foobar"
    let (handlerFut, handler) = createCompleteHandler()

    let nodes = generateNodes(2).toFloodSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[0].subscribe(topic, handler)
    waitSubscribe(nodes[1], nodes[0], topic)

    check (await nodes[1].publish(topic, "Hello!".toBytes())) > 0
    check (await handlerFut.wait(5.seconds)) == true

  asyncTest "FloodSub validation should succeed":
    const topic = "foobar"
    let (handlerFut, handler) = createCompleteHandler()

    let nodes = generateNodes(2).toFloodSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, handler)
    waitSubscribe(nodes[0], nodes[1], topic)

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      check topic == topic
      validatorFut.complete(true)
      result = ValidationResult.Accept

    nodes[1].addValidator(topic, validator)

    check (await nodes[0].publish(topic, "Hello!".toBytes())) > 0
    check (await handlerFut) == true

  asyncTest "FloodSub validation should fail":
    const topic = "foobar"
    proc handler(topic: string, data: seq[byte]) {.async.} =
      raiseAssert "Handler should not be called when validation fails"

    let nodes = generateNodes(2).toFloodSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, handler)
    waitSubscribe(nodes[0], nodes[1], topic)

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      validatorFut.complete(true)
      result = ValidationResult.Reject

    nodes[1].addValidator(topic, validator)

    discard await nodes[0].publish(topic, "Hello!".toBytes())

  asyncTest "FloodSub validation one fails and one succeeds":
    const
      topicFoo = "foo"
      topicBar = "bar"
    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == topicFoo
      handlerFut.complete(true)

    let nodes = generateNodes(2).toFloodSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topicFoo, handler)
    waitSubscribe(nodes[0], nodes[1], topicFoo)
    nodes[1].subscribe(topicBar, handler)
    waitSubscribe(nodes[0], nodes[1], topicBar)

    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      if topic == topicFoo:
        result = ValidationResult.Accept
      else:
        result = ValidationResult.Reject

    nodes[1].addValidator(topicFoo, topicBar, validator)

    check (await nodes[0].publish(topicFoo, "Hello!".toBytes())) > 0
    check (await nodes[0].publish(topicBar, "Hello!".toBytes())) > 0

  asyncTest "FloodSub multiple peers, no self trigger":
    const
      topic = "foobar"
      numberOfNodes = 10

    var futs = newSeq[(Future[void], TopicHandler, ref int)](numberOfNodes)
    for i in 0 ..< numberOfNodes:
      closureScope:
        var
          fut = newFuture[void]()
          counter = new int
        futs[i] = (
          fut,
          (
            proc(handlerTopic: string, data: seq[byte]) {.async.} =
              check handlerTopic == topic
              inc counter[]
              if counter[] == numberOfNodes - 1:
                fut.complete()
          ),
          counter,
        )

    let nodes = generateNodes(numberOfNodes, triggerSelf = false).toFloodSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, futs.mapIt(it[1]))
    waitSubscribeStar(nodes, topic)

    var pubs: seq[Future[int]]
    for i in 0 ..< numberOfNodes:
      pubs &= nodes[i].publish(topic, ("Hello!" & $i).toBytes())
    await allFuturesThrowing(pubs)

    await allFuturesThrowing(futs.mapIt(it[0]))

  asyncTest "FloodSub multiple peers, with self trigger":
    const
      topic = "foobar"
      numberOfNodes = 10

    var futs = newSeq[(Future[void], TopicHandler, ref int)](numberOfNodes)
    for i in 0 ..< numberOfNodes:
      closureScope:
        var
          fut = newFuture[void]()
          counter = new int
        futs[i] = (
          fut,
          (
            proc(handlerTopic: string, data: seq[byte]) {.async.} =
              check handlerTopic == topic
              inc counter[]
              if counter[] == numberOfNodes - 1:
                fut.complete()
          ),
          counter,
        )

    let nodes = generateNodes(numberOfNodes, triggerSelf = true).toFloodSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, futs.mapIt(it[1]))
    waitSubscribeStar(nodes, topic)

    var pubs: seq[Future[int]]
    for i in 0 ..< numberOfNodes:
      pubs &= nodes[i].publish(topic, ("Hello!" & $i).toBytes())
    await allFuturesThrowing(pubs)

    # wait the test task
    await allFuturesThrowing(futs.mapIt(it[0]))

    # test calling unsubscribeAll for coverage
    for node in nodes:
      node.unsubscribeAll(topic)
      let n = node
      checkUntilTimeout:
        n.floodsub[topic].len == numberOfNodes - 1 # we keep the peers in table
        n.topics.len == 0 # remove the topic tho

  asyncTest "FloodSub message size validation":
    const topic = "foobar"
    var messageReceived = 0
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check data.len < 50
      inc(messageReceived)

    let
      bigNode = generateNodes(1).toFloodSub()[0]
      smallNode = generateNodes(1, maxMessageSize = 200).toFloodSub()[0]
      nodes = @[bigNode, smallNode]

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, handler)
    waitSubscribeStar(nodes, topic)

    let
      bigMessage = newSeq[byte](1000)
      smallMessage1 = @[1.byte]
      smallMessage2 = @[3.byte]

    # Need two different messages, otherwise they are the same when anonymized
    check (await smallNode.publish(topic, smallMessage1)) > 0
    check (await bigNode.publish(topic, smallMessage2)) > 0

    checkUntilTimeout:
      messageReceived == 2

    check (await smallNode.publish(topic, bigMessage)) > 0
    check (await bigNode.publish(topic, bigMessage)) > 0

    await sleepAsync(300.milliseconds) # Wait before checking
    check:
      messageReceived == 2

  asyncTest "FloodSub message size validation 2":
    const topic = "foobar"
    var messageReceived = 0
    proc handler(topic: string, data: seq[byte]) {.async.} =
      inc(messageReceived)

    let nodes = generateNodes(2, maxMessageSize = 20000000).toFloodSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, handler)
    waitSubscribeStar(nodes, topic)

    let bigMessage = newSeq[byte](19000000)

    check (await nodes[0].publish(topic, bigMessage)) > 0

    checkUntilTimeout:
      messageReceived == 1

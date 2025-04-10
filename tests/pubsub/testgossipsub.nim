# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import sequtils, options, tables, sets, sugar
import chronos, stew/byteutils, chronos/ratelimit
import chronicles
import metrics
import results
import std/options
import ../../libp2p/protocols/pubsub/gossipsub/behavior
import
  utils,
  ../../libp2p/[
    errors,
    peerid,
    peerinfo,
    stream/connection,
    stream/bufferstream,
    crypto/crypto,
    protocols/pubsub/pubsub,
    protocols/pubsub/gossipsub,
    protocols/pubsub/gossipsub/scoring,
    protocols/pubsub/pubsubpeer,
    protocols/pubsub/peertable,
    protocols/pubsub/timedcache,
    protocols/pubsub/rpc/messages,
  ]
import ../../libp2p/protocols/pubsub/errors as pubsub_errors
import ../helpers, ../utils/[futures, async_tests, xtests]

from ../../libp2p/protocols/pubsub/mcache import window

proc `$`(peer: PubSubPeer): string =
  shortLog(peer)

proc voidTopicHandler(topic: string, data: seq[byte]) {.async.} =
  discard

template tryPublish(
    call: untyped, require: int, wait = 10.milliseconds, timeout = 5.seconds
): untyped =
  var
    expiration = Moment.now() + timeout
    pubs = 0
  while pubs < require and Moment.now() < expiration:
    pubs = pubs + call
    await sleepAsync(wait)

  doAssert pubs >= require, "Failed to publish!"

suite "GossipSub":
  teardown:
    checkTrackers()

  asyncTest "GossipSub validation should succeed":
    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      handlerFut.complete(true)

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    var subs: seq[Future[void]]
    subs &= waitSub(nodes[1], nodes[0], "foobar")
    subs &= waitSub(nodes[0], nodes[1], "foobar")

    await allFuturesThrowing(subs)

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      check topic == "foobar"
      validatorFut.complete(true)
      result = ValidationResult.Accept

    nodes[1].addValidator("foobar", validator)
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check (await validatorFut) and (await handlerFut)

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub validation should fail (reject)":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check false # if we get here, it should fail

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    await waitSubGraph(nodes, "foobar")

    let gossip1 = GossipSub(nodes[0])
    let gossip2 = GossipSub(nodes[1])

    check:
      gossip1.mesh["foobar"].len == 1 and "foobar" notin gossip1.fanout
      gossip2.mesh["foobar"].len == 1 and "foobar" notin gossip2.fanout

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      result = ValidationResult.Reject
      validatorFut.complete(true)

    nodes[1].addValidator("foobar", validator)
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check (await validatorFut) == true

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub validation should fail (ignore)":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check false # if we get here, it should fail

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    await waitSubGraph(nodes, "foobar")

    let gossip1 = GossipSub(nodes[0])
    let gossip2 = GossipSub(nodes[1])

    check:
      gossip1.mesh["foobar"].len == 1 and "foobar" notin gossip1.fanout
      gossip2.mesh["foobar"].len == 1 and "foobar" notin gossip2.fanout

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      result = ValidationResult.Ignore
      validatorFut.complete(true)

    nodes[1].addValidator("foobar", validator)
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check (await validatorFut) == true

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub validation one fails and one succeeds":
    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foo"
      handlerFut.complete(true)

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await subscribeNodes(nodes)

    nodes[1].subscribe("foo", handler)
    nodes[1].subscribe("bar", handler)

    var passed, failed: Future[bool] = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      result =
        if topic == "foo":
          passed.complete(true)
          ValidationResult.Accept
        else:
          failed.complete(true)
          ValidationResult.Reject

    nodes[1].addValidator("foo", "bar", validator)
    tryPublish await nodes[0].publish("foo", "Hello!".toBytes()), 1
    tryPublish await nodes[0].publish("bar", "Hello!".toBytes()), 1

    check ((await passed) and (await failed) and (await handlerFut))

    let gossip1 = GossipSub(nodes[0])
    let gossip2 = GossipSub(nodes[1])

    check:
      "foo" notin gossip1.mesh and gossip1.fanout["foo"].len == 1
      "foo" notin gossip2.mesh and "foo" notin gossip2.fanout
      "bar" notin gossip1.mesh and gossip1.fanout["bar"].len == 1
      "bar" notin gossip2.mesh and "bar" notin gossip2.fanout

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub's observers should run after message is sent, received and validated":
    var
      recvCounter = 0
      sendCounter = 0
      validatedCounter = 0

    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    proc onRecv(peer: PubSubPeer, msgs: var RPCMsg) =
      inc recvCounter

    proc onSend(peer: PubSubPeer, msgs: var RPCMsg) =
      inc sendCounter

    proc onValidated(peer: PubSubPeer, msg: Message, msgId: MessageId) =
      inc validatedCounter

    let obs0 = PubSubObserver(onSend: onSend)
    let obs1 = PubSubObserver(onRecv: onRecv, onValidated: onValidated)

    let nodes = generateNodes(2, gossip = true)
    # start switches
    discard await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await subscribeNodes(nodes)

    nodes[0].addObserver(obs0)
    nodes[1].addObserver(obs1)
    nodes[1].subscribe("foo", handler)
    nodes[1].subscribe("bar", handler)

    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      result = if topic == "foo": ValidationResult.Accept else: ValidationResult.Reject

    nodes[1].addValidator("foo", "bar", validator)

    # Send message that will be accepted by the receiver's validator
    tryPublish await nodes[0].publish("foo", "Hello!".toBytes()), 1

    check:
      recvCounter == 1
      validatedCounter == 1
      sendCounter == 1

    # Send message that will be rejected by the receiver's validator
    tryPublish await nodes[0].publish("bar", "Hello!".toBytes()), 1

    check:
      recvCounter == 2
      validatedCounter == 1
      sendCounter == 2

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

  xasyncTest "GossipSub unsub - resub faster than backoff":
    # For this test to work we'd require a way to disable fanout.
    # There's not a way to toggle it, and mocking it didn't work as there's not a reliable mock available.

    # Instantiate handlers and validators
    var handlerFut0 = newFuture[bool]()
    proc handler0(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      handlerFut0.complete(true)

    var handlerFut1 = newFuture[bool]()
    proc handler1(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      handlerFut1.complete(true)

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      check topic == "foobar"
      validatorFut.complete(true)
      result = ValidationResult.Accept

    # Setup nodes and start switches
    let
      nodes = generateNodes(2, gossip = true, unsubscribeBackoff = 5.seconds)
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())
      topic = "foobar"

    # Connect nodes
    await subscribeNodes(nodes)
    await sleepAsync(DURATION_TIMEOUT)

    # Subscribe both nodes to the topic and node1 (receiver) to the validator
    nodes[0].subscribe(topic, handler0)
    nodes[1].subscribe(topic, handler1)
    nodes[1].addValidator("foobar", validator)
    await sleepAsync(DURATION_TIMEOUT)

    # Wait for both nodes to verify others' subscription
    var subs: seq[Future[void]]
    subs &= waitSub(nodes[1], nodes[0], topic)
    subs &= waitSub(nodes[0], nodes[1], topic)
    await allFuturesThrowing(subs)

    # When unsubscribing and resubscribing in a short time frame, the backoff period should be triggered
    nodes[1].unsubscribe(topic, handler1)
    await sleepAsync(DURATION_TIMEOUT)
    nodes[1].subscribe(topic, handler1)
    await sleepAsync(DURATION_TIMEOUT)

    # Backoff is set to 5 seconds, and the amount of sleeping time since the unsubsribe until now is 3-4s~
    # Meaning, the subscription shouldn't have been processed yet because it's still in backoff period
    # When publishing under this condition
    discard await nodes[0].publish("foobar", "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # Then the message should not be received:
    check:
      validatorFut.toResult().error() == "Future still not finished."
      handlerFut1.toResult().error() == "Future still not finished."
      handlerFut0.toResult().error() == "Future still not finished."

    validatorFut.reset()
    handlerFut0.reset()
    handlerFut1.reset()

    # If we wait backoff period to end, around 1-2s
    await waitForMesh(nodes[0], nodes[1], topic, 3.seconds)

    discard await nodes[0].publish("foobar", "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # Then the message should be received
    check:
      validatorFut.toResult().isOk()
      handlerFut1.toResult().isOk()
      handlerFut0.toResult().error() == "Future still not finished."

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())
    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub should add remote peer topic subscriptions":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await subscribeNodes(nodes)

    nodes[1].subscribe("foobar", handler)

    let gossip1 = GossipSub(nodes[0])
    let gossip2 = GossipSub(nodes[1])

    checkUntilTimeout:
      "foobar" in gossip2.topics
      "foobar" in gossip1.gossipsub
      gossip1.gossipsub.hasPeerId("foobar", gossip2.peerInfo.peerId)

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub should add remote peer topic subscriptions if both peers are subscribed":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    var subs: seq[Future[void]]
    subs &= waitSub(nodes[1], nodes[0], "foobar")
    subs &= waitSub(nodes[0], nodes[1], "foobar")

    await allFuturesThrowing(subs)

    let
      gossip1 = GossipSub(nodes[0])
      gossip2 = GossipSub(nodes[1])

    check:
      "foobar" in gossip1.topics
      "foobar" in gossip2.topics

      "foobar" in gossip1.gossipsub
      "foobar" in gossip2.gossipsub

      gossip1.gossipsub.hasPeerId("foobar", gossip2.peerInfo.peerId) or
        gossip1.mesh.hasPeerId("foobar", gossip2.peerInfo.peerId)

      gossip2.gossipsub.hasPeerId("foobar", gossip1.peerInfo.peerId) or
        gossip2.mesh.hasPeerId("foobar", gossip1.peerInfo.peerId)

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub send over fanout A -> B":
    var passed = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      passed.complete()

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await subscribeNodes(nodes)

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

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())
    check observed == 2

  asyncTest "e2e - GossipSub send over fanout A -> B for subscribed topic":
    var passed = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      passed.complete()

    let
      nodes = generateNodes(2, gossip = true, unsubscribeBackoff = 10.minutes)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    GossipSub(nodes[1]).parameters.d = 0
    GossipSub(nodes[1]).parameters.dHigh = 0
    GossipSub(nodes[1]).parameters.dLow = 0

    await subscribeNodes(nodes)

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

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub send over mesh A -> B":
    var passed: Future[bool] = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      passed.complete(true)

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")

    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check await passed

    var gossip1: GossipSub = GossipSub(nodes[0])
    var gossip2: GossipSub = GossipSub(nodes[1])

    check:
      "foobar" in gossip1.gossipsub
      "foobar" in gossip2.gossipsub
      gossip1.mesh.hasPeerId("foobar", gossip2.peerInfo.peerId)
      not gossip1.fanout.hasPeerId("foobar", gossip2.peerInfo.peerId)
      gossip2.mesh.hasPeerId("foobar", gossip1.peerInfo.peerId)
      not gossip2.fanout.hasPeerId("foobar", gossip1.peerInfo.peerId)

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub should not send to source & peers who already seen":
    # 3 nodes: A, B, C
    # A publishes, C relays, B is having a long validation
    # so B should not send to anyone

    let
      nodes = generateNodes(3, gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(), nodes[1].switch.start(), nodes[2].switch.start()
      )

    await subscribeNodes(nodes)

    var cRelayed: Future[void] = newFuture[void]()
    var bFinished: Future[void] = newFuture[void]()
    var
      aReceived = 0
      cReceived = 0
    proc handlerA(topic: string, data: seq[byte]) {.async.} =
      inc aReceived
      check aReceived < 2

    proc handlerB(topic: string, data: seq[byte]) {.async.} =
      discard

    proc handlerC(topic: string, data: seq[byte]) {.async.} =
      inc cReceived
      check cReceived < 2
      cRelayed.complete()

    nodes[0].subscribe("foobar", handlerA)
    nodes[1].subscribe("foobar", handlerB)
    nodes[2].subscribe("foobar", handlerC)
    await waitSubGraph(nodes, "foobar")

    var gossip1: GossipSub = GossipSub(nodes[0])
    var gossip2: GossipSub = GossipSub(nodes[1])
    var gossip3: GossipSub = GossipSub(nodes[2])

    proc slowValidator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      try:
        await cRelayed
        # Empty A & C caches to detect duplicates
        gossip1.seen = TimedCache[SaltedId].init()
        gossip3.seen = TimedCache[SaltedId].init()
        let msgId = toSeq(gossip2.validationSeen.keys)[0]
        checkUntilTimeout(
          try:
            gossip2.validationSeen[msgId].len > 0
          except KeyError:
            false
        )
        result = ValidationResult.Accept
        bFinished.complete()
      except CatchableError:
        raiseAssert "err on slowValidator"

    nodes[1].addValidator("foobar", slowValidator)

    checkUntilTimeout:
      gossip1.mesh.getOrDefault("foobar").len == 2
      gossip2.mesh.getOrDefault("foobar").len == 2
      gossip3.mesh.getOrDefault("foobar").len == 2
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 2

    await bFinished

    await allFuturesThrowing(
      nodes[0].switch.stop(), nodes[1].switch.stop(), nodes[2].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub send over floodPublish A -> B":
    var passed: Future[bool] = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      passed.complete(true)

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    var gossip1: GossipSub = GossipSub(nodes[0])
    gossip1.parameters.floodPublish = true
    var gossip2: GossipSub = GossipSub(nodes[1])
    gossip2.parameters.floodPublish = true

    await subscribeNodes(nodes)

    # nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")

    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check await passed.wait(10.seconds)

    check:
      "foobar" in gossip1.gossipsub
      "foobar" notin gossip2.gossipsub
      not gossip1.mesh.hasPeerId("foobar", gossip2.peerInfo.peerId)

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  # Helper procedures to avoid repetition
  proc setupNodes(count: int): seq[PubSub] =
    generateNodes(count, gossip = true)

  proc startNodes(nodes: seq[PubSub]) {.async.} =
    await allFuturesThrowing(nodes.mapIt(it.switch.start()))

  proc stopNodes(nodes: seq[PubSub]) {.async.} =
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))

  proc connectNodes(nodes: seq[PubSub], target: PubSub) {.async.} =
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"

    for node in nodes:
      node.subscribe("foobar", handler)
      await node.switch.connect(target.peerInfo.peerId, target.peerInfo.addrs)

  proc baseTestProcedure(
      nodes: seq[PubSub],
      gossip1: GossipSub,
      numPeersFirstMsg: int,
      numPeersSecondMsg: int,
  ) {.async.} =
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"

    block setup:
      for i in 0 ..< 50:
        if (await nodes[0].publish("foobar", ("Hello!" & $i).toBytes())) == 19:
          break setup
        await sleepAsync(10.milliseconds)
      check false

    check (await nodes[0].publish("foobar", newSeq[byte](2_500_000))) == numPeersFirstMsg
    check (await nodes[0].publish("foobar", newSeq[byte](500_001))) == numPeersSecondMsg

    # Now try with a mesh
    gossip1.subscribe("foobar", handler)
    checkUntilTimeout:
      gossip1.mesh.peers("foobar") > 5

    # use a different length so that the message is not equal to the last
    check (await nodes[0].publish("foobar", newSeq[byte](500_000))) == numPeersSecondMsg

  # Actual tests
  asyncTest "e2e - GossipSub floodPublish limit":
    let
      nodes = setupNodes(20)
      gossip1 = GossipSub(nodes[0])

    gossip1.parameters.floodPublish = true
    gossip1.parameters.heartbeatInterval = milliseconds(700)

    await startNodes(nodes)
    await connectNodes(nodes[1 ..^ 1], nodes[0])
    await baseTestProcedure(nodes, gossip1, gossip1.parameters.dLow, 17)
    await stopNodes(nodes)

  asyncTest "e2e - GossipSub floodPublish limit with bandwidthEstimatebps = 0":
    let
      nodes = setupNodes(20)
      gossip1 = GossipSub(nodes[0])

    gossip1.parameters.floodPublish = true
    gossip1.parameters.heartbeatInterval = milliseconds(700)
    gossip1.parameters.bandwidthEstimatebps = 0

    await startNodes(nodes)
    await connectNodes(nodes[1 ..^ 1], nodes[0])
    await baseTestProcedure(nodes, gossip1, nodes.len - 1, nodes.len - 1)
    await stopNodes(nodes)

  asyncTest "e2e - GossipSub with multiple peers":
    var runs = 10

    let
      nodes = generateNodes(runs, gossip = true, triggerSelf = true)
      nodesFut = nodes.mapIt(it.switch.start())

    await subscribeNodes(nodes)

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

    tryPublish await wait(
      nodes[0].publish("foobar", toBytes("from node " & $nodes[0].peerInfo.peerId)),
      1.minutes,
    ), 1

    await wait(seenFut, 1.minutes)
    check:
      seen.len >= runs
    for k, v in seen.pairs:
      check:
        v >= 1

    for node in nodes:
      var gossip = GossipSub(node)

      check:
        "foobar" in gossip.gossipsub

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

    await allFuturesThrowing(nodesFut)

  asyncTest "e2e - GossipSub with multiple peers (sparse)":
    var runs = 10

    let
      nodes = generateNodes(runs, gossip = true, triggerSelf = true)
      nodesFut = nodes.mapIt(it.switch.start())

    await subscribeSparseNodes(nodes)

    var seen: Table[string, int]
    var seenFut = newFuture[void]()

    for i in 0 ..< nodes.len:
      let dialer = nodes[i]
      var handler: TopicHandler
      capture dialer, i:
        var peerName = $dialer.peerInfo.peerId
        handler = proc(topic: string, data: seq[byte]) {.async.} =
          try:
            if peerName notin seen:
              seen[peerName] = 0
            seen[peerName].inc
          except KeyError:
            raiseAssert "seen checked before"
          check topic == "foobar"
          if not seenFut.finished() and seen.len >= runs:
            seenFut.complete()

      dialer.subscribe("foobar", handler)

    await waitSubGraph(nodes, "foobar")
    tryPublish await wait(
      nodes[0].publish("foobar", toBytes("from node " & $nodes[0].peerInfo.peerId)),
      1.minutes,
    ), 1

    await wait(seenFut, 60.seconds)
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

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

    await allFuturesThrowing(nodesFut)

  asyncTest "e2e - GossipSub peer exchange":
    # A, B & C are subscribed to something
    # B unsubcribe from it, it should send
    # PX to A & C
    #
    # C sent his SPR, not A
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard # not used in this test

    let
      nodes =
        generateNodes(2, gossip = true, enablePX = true) &
        generateNodes(1, gossip = true, sendSignedPeerRecord = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(), nodes[1].switch.start(), nodes[2].switch.start()
      )

    var
      gossip0 = GossipSub(nodes[0])
      gossip1 = GossipSub(nodes[1])
      gossip2 = GossipSub(nodes[2])

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)
    nodes[2].subscribe("foobar", handler)
    for x in 0 ..< 3:
      for y in 0 ..< 3:
        if x != y:
          await waitSub(nodes[x], nodes[y], "foobar")

    # Setup record handlers for all nodes
    var
      passed0: Future[void] = newFuture[void]()
      passed1: Future[void] = newFuture[void]()
      passed2: Future[void] = newFuture[void]()
    gossip0.routingRecordsHandler.add(
      proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
        check:
          tag == "foobar"
          peers.len == 2
          peers[0].record.isSome() xor peers[1].record.isSome()
        passed0.complete()
    )
    gossip1.routingRecordsHandler.add(
      proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
        passed1.complete()
    )
    gossip2.routingRecordsHandler.add(
      proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
        check:
          tag == "foobar"
          peers.len == 2
          peers[0].record.isSome() xor peers[1].record.isSome()
        passed2.complete()
    )

    # Unsubscribe from the topic
    nodes[1].unsubscribe("foobar", handler)

    # Then verify what nodes receive the PX
    check:
      (await passed0.waitForResult()).isOk
      not (await passed1.waitForResult()).isOk
      (await passed2.waitForResult()).isOk

    await allFuturesThrowing(
      nodes[0].switch.stop(), nodes[1].switch.stop(), nodes[2].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - iDontWant":
    # 3 nodes: A <=> B <=> C
    # (A & C are NOT connected). We pre-emptively send a dontwant from C to B,
    # and check that B doesn't relay the message to C.
    # We also check that B sends IDONTWANT to C, but not A
    func dumbMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      ok(newSeq[byte](10))
    let
      nodes = generateNodes(3, gossip = true, msgIdProvider = dumbMsgIdProvider)

      nodesFut = await allFinished(
        nodes[0].switch.start(), nodes[1].switch.start(), nodes[2].switch.start()
      )

    await nodes[0].switch.connect(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )
    await nodes[1].switch.connect(
      nodes[2].switch.peerInfo.peerId, nodes[2].switch.peerInfo.addrs
    )

    let bFinished = newFuture[void]()
    proc handlerA(topic: string, data: seq[byte]) {.async.} =
      discard

    proc handlerB(topic: string, data: seq[byte]) {.async.} =
      bFinished.complete()

    proc handlerC(topic: string, data: seq[byte]) {.async.} =
      doAssert false

    nodes[0].subscribe("foobar", handlerA)
    nodes[1].subscribe("foobar", handlerB)
    nodes[2].subscribe("foobar", handlerB)
    await waitSubGraph(nodes, "foobar")

    var gossip1: GossipSub = GossipSub(nodes[0])
    var gossip2: GossipSub = GossipSub(nodes[1])
    var gossip3: GossipSub = GossipSub(nodes[2])

    check:
      gossip3.mesh.peers("foobar") == 1

    gossip3.broadcast(
      gossip3.mesh["foobar"],
      RPCMsg(
        control: some(
          ControlMessage(idontwant: @[ControlIWant(messageIDs: @[newSeq[byte](10)])])
        )
      ),
      isHighPriority = true,
    )
    checkUntilTimeout:
      gossip2.mesh.getOrDefault("foobar").anyIt(it.iDontWants[^1].len == 1)

    tryPublish await nodes[0].publish("foobar", newSeq[byte](10000)), 1

    await bFinished

    checkUntilTimeout:
      toSeq(gossip3.mesh.getOrDefault("foobar")).anyIt(it.iDontWants[^1].len == 1)
    check:
      toSeq(gossip1.mesh.getOrDefault("foobar")).anyIt(it.iDontWants[^1].len == 0)

    await allFuturesThrowing(
      nodes[0].switch.stop(), nodes[1].switch.stop(), nodes[2].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - iDontWant is broadcasted on publish":
    func dumbMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      ok(newSeq[byte](10))
    let
      nodes = generateNodes(
        2,
        gossip = true,
        msgIdProvider = dumbMsgIdProvider,
        sendIDontWantOnPublish = true,
      )

      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await nodes[0].switch.connect(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )

    proc handlerA(topic: string, data: seq[byte]) {.async.} =
      discard

    proc handlerB(topic: string, data: seq[byte]) {.async.} =
      discard

    nodes[0].subscribe("foobar", handlerA)
    nodes[1].subscribe("foobar", handlerB)
    await waitSubGraph(nodes, "foobar")

    var gossip2: GossipSub = GossipSub(nodes[1])

    tryPublish await nodes[0].publish("foobar", newSeq[byte](10000)), 1

    checkUntilTimeout:
      gossip2.mesh.getOrDefault("foobar").anyIt(it.iDontWants[^1].len == 1)

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - iDontWant is sent only for 1.2":
    # 3 nodes: A <=> B <=> C
    # (A & C are NOT connected). We pre-emptively send a dontwant from C to B,
    # and check that B doesn't relay the message to C.
    # We also check that B sends IDONTWANT to C, but not A
    func dumbMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      ok(newSeq[byte](10))
    let
      nodeA = generateNodes(1, gossip = true, msgIdProvider = dumbMsgIdProvider)[0]
      nodeB = generateNodes(1, gossip = true, msgIdProvider = dumbMsgIdProvider)[0]
      nodeC = generateNodes(
        1,
        gossip = true,
        msgIdProvider = dumbMsgIdProvider,
        gossipSubVersion = GossipSubCodec_11,
      )[0]

    let nodesFut = await allFinished(
      nodeA.switch.start(), nodeB.switch.start(), nodeC.switch.start()
    )

    await nodeA.switch.connect(
      nodeB.switch.peerInfo.peerId, nodeB.switch.peerInfo.addrs
    )
    await nodeB.switch.connect(
      nodeC.switch.peerInfo.peerId, nodeC.switch.peerInfo.addrs
    )

    let bFinished = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    proc handlerB(topic: string, data: seq[byte]) {.async.} =
      bFinished.complete()

    nodeA.subscribe("foobar", handler)
    nodeB.subscribe("foobar", handlerB)
    nodeC.subscribe("foobar", handler)
    await waitSubGraph(@[nodeA, nodeB, nodeC], "foobar")

    var gossipA: GossipSub = GossipSub(nodeA)
    var gossipB: GossipSub = GossipSub(nodeB)
    var gossipC: GossipSub = GossipSub(nodeC)

    check:
      gossipC.mesh.peers("foobar") == 1

    tryPublish await nodeA.publish("foobar", newSeq[byte](10000)), 1

    await bFinished

    # "check" alone isn't suitable for testing that a condition is true after some time has passed. Below we verify that
    # peers A and C haven't received an IDONTWANT message from B, but we need wait some time for potential in flight messages to arrive.
    await sleepAsync(500.millis)
    check:
      toSeq(gossipC.mesh.getOrDefault("foobar")).anyIt(it.iDontWants[^1].len == 0)
      toSeq(gossipA.mesh.getOrDefault("foobar")).anyIt(it.iDontWants[^1].len == 0)

    await allFuturesThrowing(
      nodeA.switch.stop(), nodeB.switch.stop(), nodeC.switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  proc initializeGossipTest(): Future[(seq[PubSub], GossipSub, GossipSub)] {.async.} =
    let nodes =
      generateNodes(2, gossip = true, overheadRateLimit = Opt.some((20, 1.millis)))

    discard await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await subscribeNodes(nodes)

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
    await sleepAsync(300.millis)

    check currentRateLimitHits() == rateLimitHits
    check gossip1.switch.isConnected(gossip0.switch.peerInfo.peerId) == true

    # Disconnect peer when rate limiting is enabled
    gossip1.parameters.disconnectPeerAboveRateLimit = true
    gossip0.broadcast(
      gossip0.mesh["foobar"],
      RPCMsg(messages: @[Message(topic: "foobar", data: newSeq[byte](12))]),
      isHighPriority = true,
    )
    await sleepAsync(300.millis)

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
    await sleepAsync(300.millis)

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
    await sleepAsync(300.millis)

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
    await sleepAsync(300.millis)

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

  asyncTest "Peer must send right gosspipsub version":
    func dumbMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      ok(newSeq[byte](10))
    let node0 = generateNodes(1, gossip = true, msgIdProvider = dumbMsgIdProvider)[0]
    let node1 = generateNodes(
      1,
      gossip = true,
      msgIdProvider = dumbMsgIdProvider,
      gossipSubVersion = GossipSubCodec_10,
    )[0]

    let nodesFut = await allFinished(node0.switch.start(), node1.switch.start())

    await node0.switch.connect(
      node1.switch.peerInfo.peerId, node1.switch.peerInfo.addrs
    )

    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    node0.subscribe("foobar", handler)
    node1.subscribe("foobar", handler)
    await waitSubGraph(@[node0, node1], "foobar")

    var gossip0: GossipSub = GossipSub(node0)
    var gossip1: GossipSub = GossipSub(node1)

    checkUntilTimeout:
      gossip0.mesh.getOrDefault("foobar").toSeq[0].codec == GossipSubCodec_10
    checkUntilTimeout:
      gossip1.mesh.getOrDefault("foobar").toSeq[0].codec == GossipSubCodec_10

    await allFuturesThrowing(node0.switch.stop(), node1.switch.stop())

    await allFuturesThrowing(nodesFut.concat())

suite "Gossipsub Parameters":
  teardown:
    checkTrackers()

  asyncTest "dont prune peers if mesh len is less than d_high":
    let
      numberOfNodes = 5
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)
      nodesFut = await allFinished(nodes.mapIt(it.switch.start()))

    await subscribeNodes(nodes)

    for node in nodes:
      node.subscribe(topic, voidTopicHandler)

    for x in 0 ..< numberOfNodes:
      for y in 0 ..< numberOfNodes:
        if x != y:
          await waitSub(nodes[x], nodes[y], topic)

    let expectedNumberOfPeers = numberOfNodes - 1
    for i in 0 ..< numberOfNodes:
      var gossip = GossipSub(nodes[i])
      check:
        gossip.gossipsub[topic].len == expectedNumberOfPeers
        gossip.mesh[topic].len == expectedNumberOfPeers
        gossip.fanout.len == 0

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

  asyncTest "prune peers if mesh len is higher than d_high":
    let
      numberofNodes = 15
      topic = "foobar"
      nodes = generateNodes(numberofNodes, gossip = true)
      nodesFut = await allFinished(nodes.mapIt(it.switch.start()))

    await subscribeNodes(nodes)

    for node in nodes:
      node.subscribe(topic, voidTopicHandler)

    for x in 0 ..< numberofNodes:
      for y in 0 ..< numberofNodes:
        if x != y:
          await waitSub(nodes[x], nodes[y], topic)

    # Give it time for a heartbeat
    await sleepAsync(DURATION_TIMEOUT_EXTENDED)

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

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

  asyncTest "messages sent to peers not in the mesh are propagated via gossip":
    # Given 5 nodes
    let
      numberOfNodes = 5
      topic = "foobar"
      dValues = DValues(dLow: some(2), dHigh: some(3), d: some(2), dOut: some(1))
      nodes = generateNodes(numberOfNodes, gossip = true, dValues = some(dValues))
      nodesFut = await allFinished(nodes.mapIt(it.switch.start()))

    # All of them are checking for iHave messages
    var receivedIHaves: seq[int] = repeat(0, numberOfNodes)
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

    # All of them are interconnected
    await subscribeNodes(nodes)

    # And subscribed to the same topic
    for node in nodes:
      node.subscribe(topic, voidTopicHandler)
    await sleepAsync(DURATION_TIMEOUT)

    # When node 0 sends a message
    discard nodes[0].publish(topic, "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # At least one of the nodes should have received an iHave message
    # The check is made this way because the mesh structure changes from run to run
    check:
      anyIt(receivedIHaves, it > 0)

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

  asyncTest "messages are not sent back to source or forwarding peer":
    # Instantiate 3 nodes
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)
      nodesFut = await allFinished(nodes.mapIt(it.switch.start()))
      node0 = nodes[0]
      node1 = nodes[1]
      node2 = nodes[2]

    # Each node with a handler
    var
      handlerFuture0 = newFuture[bool]()
      handlerFuture1 = newFuture[bool]()
      handlerFuture2 = newFuture[bool]()

    proc handler0(topic: string, data: seq[byte]) {.async.} =
      handlerFuture0.complete(true)

    proc handler1(topic: string, data: seq[byte]) {.async.} =
      handlerFuture1.complete(true)

    proc handler2(topic: string, data: seq[byte]) {.async.} =
      handlerFuture2.complete(true)

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
    check:
      (await handlerFuture0.waitForResult()).isErr
      (await handlerFuture1.waitForResult()).isOk
      (await handlerFuture2.waitForResult()).isOk

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

  asyncTest "flood publish to all peers with score above threshold, regardless of subscription":
    # Given 3 nodes
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true, floodPublish = true)
      nodesFut = nodes.mapIt(it.switch.start())
      g0 = GossipSub(nodes[0])

    # Nodes 1 and 2 are connected to node 0
    await nodes[0].switch.connect(nodes[1].peerInfo.peerId, nodes[1].peerInfo.addrs)
    await nodes[0].switch.connect(nodes[2].peerInfo.peerId, nodes[2].peerInfo.addrs)

    # Given 2 handlers
    var
      handlerFut1 = newFuture[bool]()
      handlerFut2 = newFuture[bool]()

    proc handler1(topic: string, data: seq[byte]) {.async.} =
      handlerFut1.complete(true)

    proc handler2(topic: string, data: seq[byte]) {.async.} =
      handlerFut2.complete(true)

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
    check (await nodes[0].publish(topic, message)) > 0
    await sleepAsync(3.seconds)

    # Then only node 1 should receive the message
    let
      result1 = await handlerFut1.waitForResult(DURATION_TIMEOUT)
      result2 = await handlerFut2.waitForResult(DURATION_TIMEOUT)
    check:
      result1.isOk and result1.get == true
      result2.isErr

    # Cleanup
    await allFuturesThrowing(nodes.mapIt(it.switch.stop()))
    await allFuturesThrowing(nodesFut)

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
      nodesFut = await allFinished(nodes.mapIt(it.switch.start()))

    # All of them are checking for iHave messages
    var receivedIHaves: seq[int] = repeat(0, numberOfNodes)
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
    check:
      filterIt(receivedIHaves, it > 0).len == 0

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

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
      nodesFut = await allFinished(nodes.mapIt(it.switch.start()))

    # All of them are checking for iHave messages
    var receivedIHaves: seq[int] = repeat(0, numberOfNodes)
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
    check:
      filterIt(receivedIHaves, it > 0).len >= 8

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

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
      nodesFut = await allFinished(nodes.mapIt(it.switch.start()))

    # All of them are checking for iHave messages
    var receivedIHaves: seq[int] = repeat(0, numberOfNodes)
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
    check:
      filterIt(receivedIHaves, it > 0).len == 6

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

  asyncTest "iDontWant messages are broadcast immediately after receiving the first message instance":
    # Given 3 nodes
    let
      numberOfNodes = 3
      topic = "foobar"
      nodes = generateNodes(numberOfNodes, gossip = true)
      nodesFut = await allFinished(nodes.mapIt(it.switch.start()))
      node0 = nodes[0]
      node1 = nodes[1]
      node2 = nodes[2]

    # And with iDontWant observers
    var
      iDontWantReceived0 = newFuture[bool]()
      iDontWantReceived1 = newFuture[bool]()
      iDontWantReceived2 = newFuture[bool]()

    proc observer0(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        let iDontWant = msgs.control.get.idontwant
        if iDontWant.len > 0:
          iDontWantReceived0.complete(true)

    proc observer1(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        let iDontWant = msgs.control.get.idontwant
        if iDontWant.len > 0:
          iDontWantReceived1.complete(true)

    proc observer2(peer: PubSubPeer, msgs: var RPCMsg) =
      if msgs.control.isSome:
        let iDontWant = msgs.control.get.idontwant
        if iDontWant.len > 0:
          iDontWantReceived2.complete(true)

    node0.addObserver(PubSubObserver(onRecv: observer0))
    node1.addObserver(PubSubObserver(onRecv: observer1))
    node2.addObserver(PubSubObserver(onRecv: observer2))

    # Connect them in a line
    await node0.switch.connect(node1.peerInfo.peerId, node1.peerInfo.addrs)
    await node1.switch.connect(node2.peerInfo.peerId, node2.peerInfo.addrs)
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
    check:
      (await iDontWantReceived0.waitForResult()).isErr
      (await iDontWantReceived1.waitForResult()).isErr
      (await iDontWantReceived2.waitForResult()).isOk

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

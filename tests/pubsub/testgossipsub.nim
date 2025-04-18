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
import
  utils,
  ../../libp2p/[
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
import ../helpers, ../utils/[futures, async_tests]

from ../../libp2p/protocols/pubsub/mcache import window

proc `$`(peer: PubSubPeer): string =
  shortLog(peer)

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

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

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

  asyncTest "GossipSub validation should fail (reject)":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check false # if we get here, it should fail

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

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

  asyncTest "GossipSub validation should fail (ignore)":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check false # if we get here, it should fail

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

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

  asyncTest "GossipSub validation one fails and one succeeds":
    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foo"
      handlerFut.complete(true)

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

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

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

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

  asyncTest "GossipSub unsub - resub faster than backoff":
    # For this test to work we'd require a way to disable fanout.
    # There's not a way to toggle it, and mocking it didn't work as there's not a reliable mock available.
    skip()
    return

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
      topic = "foobar"

    # Connect nodes
    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

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
      validatorFut.toState().isPending()
      handlerFut1.toState().isPending()
      handlerFut0.toState().isPending()

    validatorFut.reset()
    handlerFut0.reset()
    handlerFut1.reset()

    # If we wait backoff period to end, around 1-2s
    await waitForMesh(nodes[0], nodes[1], topic, 3.seconds)

    discard await nodes[0].publish("foobar", "Hello!".toBytes())
    await sleepAsync(DURATION_TIMEOUT)

    # Then the message should be received
    check:
      validatorFut.toState().isCompleted()
      handlerFut1.toState().isCompleted()
      handlerFut0.toState().isPending()

  asyncTest "e2e - GossipSub should add remote peer topic subscriptions":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe("foobar", handler)

    let gossip1 = GossipSub(nodes[0])
    let gossip2 = GossipSub(nodes[1])

    checkUntilTimeout:
      "foobar" in gossip2.topics
      "foobar" in gossip1.gossipsub
      gossip1.gossipsub.hasPeerId("foobar", gossip2.peerInfo.peerId)

  asyncTest "e2e - GossipSub should add remote peer topic subscriptions if both peers are subscribed":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

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

  asyncTest "e2e - GossipSub send over mesh A -> B":
    var passed: Future[bool] = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      passed.complete(true)

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

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

  asyncTest "e2e - GossipSub should not send to source & peers who already seen":
    # 3 nodes: A, B, C
    # A publishes, C relays, B is having a long validation
    # so B should not send to anyone

    let nodes = generateNodes(3, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

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

  asyncTest "e2e - GossipSub send over floodPublish A -> B":
    var passed: Future[bool] = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == "foobar"
      passed.complete(true)

    let nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)

    var gossip1: GossipSub = GossipSub(nodes[0])
    gossip1.parameters.floodPublish = true
    var gossip2: GossipSub = GossipSub(nodes[1])
    gossip2.parameters.floodPublish = true

    await connectNodesStar(nodes)

    # nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")

    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check await passed.wait(10.seconds)

    check:
      "foobar" in gossip1.gossipsub
      "foobar" notin gossip2.gossipsub
      not gossip1.mesh.hasPeerId("foobar", gossip2.peerInfo.peerId)

  # Helper procedures to avoid repetition
  proc setupNodes(count: int): seq[PubSub] =
    generateNodes(count, gossip = true)

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

    startNodesAndDeferStop(nodes)
    await connectNodes(nodes[1 ..^ 1], nodes[0])
    await baseTestProcedure(nodes, gossip1, gossip1.parameters.dLow, 17)

  asyncTest "e2e - GossipSub floodPublish limit with bandwidthEstimatebps = 0":
    let
      nodes = setupNodes(20)
      gossip1 = GossipSub(nodes[0])

    gossip1.parameters.floodPublish = true
    gossip1.parameters.heartbeatInterval = milliseconds(700)
    gossip1.parameters.bandwidthEstimatebps = 0

    startNodesAndDeferStop(nodes)
    await connectNodes(nodes[1 ..^ 1], nodes[0])
    await baseTestProcedure(nodes, gossip1, nodes.len - 1, nodes.len - 1)

  asyncTest "e2e - GossipSub with multiple peers":
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

  asyncTest "e2e - GossipSub with multiple peers (sparse)":
    var runs = 10

    let nodes = generateNodes(runs, gossip = true, triggerSelf = true)

    startNodesAndDeferStop(nodes)
    await connectNodesSparse(nodes)

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

  asyncTest "e2e - GossipSub peer exchange":
    # A, B & C are subscribed to something
    # B unsubcribe from it, it should send
    # PX to A & C
    #
    # C sent his SPR, not A
    proc handler(topic: string, data: seq[byte]) {.async.} =
      discard # not used in this test

    let nodes =
      generateNodes(2, gossip = true, enablePX = true) &
      generateNodes(1, gossip = true, sendSignedPeerRecord = true)

    startNodesAndDeferStop(nodes)

    var
      gossip0 = GossipSub(nodes[0])
      gossip1 = GossipSub(nodes[1])
      gossip2 = GossipSub(nodes[2])

    await connectNodesStar(nodes)

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
        raiseAssert "should not get here"
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
    let results = await waitForStates(@[passed0, passed2])
    check:
      results[0].isCompleted()
      results[1].isCompleted()

  asyncTest "e2e - iDontWant":
    # 3 nodes: A <=> B <=> C
    # (A & C are NOT connected). We pre-emptively send a dontwant from C to B,
    # and check that B doesn't relay the message to C.
    # We also check that B sends IDONTWANT to C, but not A
    func dumbMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      ok(newSeq[byte](10))
    let nodes = generateNodes(3, gossip = true, msgIdProvider = dumbMsgIdProvider)

    startNodesAndDeferStop(nodes)

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

  asyncTest "e2e - iDontWant is broadcasted on publish":
    func dumbMsgIdProvider(m: Message): Result[MessageId, ValidationResult] =
      ok(newSeq[byte](10))
    let nodes = generateNodes(
      2, gossip = true, msgIdProvider = dumbMsgIdProvider, sendIDontWantOnPublish = true
    )

    startNodesAndDeferStop(nodes)

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

    startNodesAndDeferStop(@[nodeA, nodeB, nodeC])

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

    startNodesAndDeferStop(@[node0, node1])

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

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
import chronos, stew/byteutils
import chronicles
import utils, ../../libp2p/[errors,
                            peerid,
                            peerinfo,
                            stream/connection,
                            stream/bufferstream,
                            crypto/crypto,
                            protocols/pubsub/pubsub,
                            protocols/pubsub/gossipsub,
                            protocols/pubsub/pubsubpeer,
                            protocols/pubsub/peertable,
                            protocols/pubsub/timedcache,
                            protocols/pubsub/rpc/messages]
import ../../libp2p/protocols/pubsub/errors as pubsub_errors
import ../helpers

proc `$`(peer: PubSubPeer): string = shortLog(peer)

template tryPublish(call: untyped, require: int, wait = 10.milliseconds, timeout = 5.seconds): untyped =
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
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check topic == "foobar"
      handlerFut.complete(true)

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    var subs: seq[Future[void]]
    subs &= waitSub(nodes[1], nodes[0], "foobar")
    subs &= waitSub(nodes[0], nodes[1], "foobar")

    await allFuturesThrowing(subs)

    var validatorFut = newFuture[bool]()
    proc validator(topic: string,
                    message: Message):
                    Future[ValidationResult] {.async.} =
      check topic == "foobar"
      validatorFut.complete(true)
      result = ValidationResult.Accept

    nodes[1].addValidator("foobar", validator)
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check (await validatorFut) and (await handlerFut)

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub validation should fail (reject)":
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check false # if we get here, it should fail

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

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
    proc validator(topic: string,
                    message: Message):
                    Future[ValidationResult] {.async.} =
      result = ValidationResult.Reject
      validatorFut.complete(true)

    nodes[1].addValidator("foobar", validator)
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check (await validatorFut) == true

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub validation should fail (ignore)":
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check false # if we get here, it should fail

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

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
    proc validator(topic: string,
                    message: Message):
                    Future[ValidationResult] {.async.} =
      result = ValidationResult.Ignore
      validatorFut.complete(true)

    nodes[1].addValidator("foobar", validator)
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check (await validatorFut) == true

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub validation one fails and one succeeds":
    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check topic == "foo"
      handlerFut.complete(true)

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

    await subscribeNodes(nodes)

    nodes[1].subscribe("foo", handler)
    nodes[1].subscribe("bar", handler)

    var passed, failed: Future[bool] = newFuture[bool]()
    proc validator(topic: string,
                    message: Message):
                    Future[ValidationResult] {.async.} =
      result = if topic == "foo":
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

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub unsub - resub faster than backoff":
    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check topic == "foobar"
      handlerFut.complete(true)

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    var subs: seq[Future[void]]
    subs &= waitSub(nodes[1], nodes[0], "foobar")
    subs &= waitSub(nodes[0], nodes[1], "foobar")

    await allFuturesThrowing(subs)

    nodes[0].unsubscribe("foobar", handler)
    nodes[0].subscribe("foobar", handler)

    # regular backoff is 60 seconds, so we must not wait that long
    await (waitSub(nodes[0], nodes[1], "foobar") and waitSub(nodes[1], nodes[0], "foobar")).wait(30.seconds)

    var validatorFut = newFuture[bool]()
    proc validator(topic: string,
                    message: Message):
                    Future[ValidationResult] {.async.} =
      check topic == "foobar"
      validatorFut.complete(true)
      result = ValidationResult.Accept

    nodes[1].addValidator("foobar", validator)
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check (await validatorFut) and (await handlerFut)

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub should add remote peer topic subscriptions":
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      discard

    let
      nodes = generateNodes(
        2,
        gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

    await subscribeNodes(nodes)

    nodes[1].subscribe("foobar", handler)

    let gossip1 = GossipSub(nodes[0])
    let gossip2 = GossipSub(nodes[1])

    checkExpiring:
      "foobar" in gossip2.topics and
      "foobar" in gossip1.gossipsub and
      gossip1.gossipsub.hasPeerId("foobar", gossip2.peerInfo.peerId)

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub should add remote peer topic subscriptions if both peers are subscribed":
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      discard

    let
      nodes = generateNodes(
        2,
        gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

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

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub send over fanout A -> B":
    var passed = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check topic == "foobar"
      passed.complete()

    let
      nodes = generateNodes(
        2,
        gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

    await subscribeNodes(nodes)

    nodes[1].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")

    var observed = 0
    let
      obs1 = PubSubObserver(onRecv: proc(peer: PubSubPeer; msgs: var RPCMsg) =
        inc observed
      )
      obs2 = PubSubObserver(onSend: proc(peer: PubSubPeer; msgs: var RPCMsg) =
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

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())
    check observed == 2

  asyncTest "e2e - GossipSub send over fanout A -> B for subscribed topic":
    var passed = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check topic == "foobar"
      passed.complete()

    let
      nodes = generateNodes(
        2,
        gossip = true,
        unsubscribeBackoff = 10.minutes)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

    GossipSub(nodes[1]).parameters.d = 0
    GossipSub(nodes[1]).parameters.dHigh = 0
    GossipSub(nodes[1]).parameters.dLow = 0

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    let gsNode = GossipSub(nodes[1])
    checkExpiring:
      gsNode.mesh.getOrDefault("foobar").len == 0 and
      GossipSub(nodes[0]).mesh.getOrDefault("foobar").len == 0 and
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

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub send over mesh A -> B":
    var passed: Future[bool] = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check topic == "foobar"
      passed.complete(true)

    let
      nodes = generateNodes(
        2,
        gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

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

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub should not send to source & peers who already seen":
    # 3 nodes: A, B, C
    # A publishes, C relays, B is having a long validation
    # so B should not send to anyone

    let
      nodes = generateNodes(
        3,
        gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
        nodes[2].switch.start(),
      )

    await subscribeNodes(nodes)

    var cRelayed: Future[void] = newFuture[void]()
    var bFinished: Future[void] = newFuture[void]()
    var
      aReceived = 0
      cReceived = 0
    proc handlerA(topic: string, data: seq[byte]) {.async, gcsafe.} =
      inc aReceived
      check aReceived < 2
    proc handlerB(topic: string, data: seq[byte]) {.async, gcsafe.} = discard
    proc handlerC(topic: string, data: seq[byte]) {.async, gcsafe.} =
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

    proc slowValidator(topic: string, message: Message): Future[ValidationResult] {.async.} =
      await cRelayed
      # Empty A & C caches to detect duplicates
      gossip1.seen = TimedCache[MessageId].init()
      gossip3.seen = TimedCache[MessageId].init()
      let msgId = toSeq(gossip2.validationSeen.keys)[0]
      checkExpiring(try: gossip2.validationSeen[msgId].len > 0 except: false)
      result = ValidationResult.Accept
      bFinished.complete()

    nodes[1].addValidator("foobar", slowValidator)

    checkExpiring(
      gossip1.mesh.getOrDefault("foobar").len == 2 and
      gossip2.mesh.getOrDefault("foobar").len == 2 and
      gossip3.mesh.getOrDefault("foobar").len == 2)
    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 2

    await bFinished

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop(),
      nodes[2].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub send over floodPublish A -> B":
    var passed: Future[bool] = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check topic == "foobar"
      passed.complete(true)

    let
      nodes = generateNodes(
        2,
        gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
      )

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
      not gossip1.fanout.hasPeerId("foobar", gossip2.peerInfo.peerId)

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub floodPublish limit":
    var passed: Future[bool] = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check topic == "foobar"

    let
      nodes = generateNodes(
        20,
        gossip = true)

    await allFuturesThrowing(
      nodes.mapIt(it.switch.start())
    )

    var gossip1: GossipSub = GossipSub(nodes[0])
    gossip1.parameters.floodPublish = true
    gossip1.parameters.heartbeatInterval = milliseconds(700)

    for node in nodes[1..^1]:
      node.subscribe("foobar", handler)
      await node.switch.connect(nodes[0].peerInfo.peerId, nodes[0].peerInfo.addrs)

    block setup:
      for i in 0..<50:
        if (await nodes[0].publish("foobar", ("Hello!" & $i).toBytes())) == 19:
          break setup
        await sleepAsync(10.milliseconds)
      check false

    check (await nodes[0].publish("foobar", newSeq[byte](1_000_000))) == 17

    # Now try with a mesh
    gossip1.subscribe("foobar", handler)
    checkExpiring: gossip1.mesh.peers("foobar") > 5

    # use a different length so that the message is not equal to the last
    check (await nodes[0].publish("foobar", newSeq[byte](1_000_001))) == 17

    await allFuturesThrowing(
      nodes.mapIt(it.switch.stop())
    )

  asyncTest "e2e - GossipSub with multiple peers":
    var runs = 10

    let
      nodes = generateNodes(runs, gossip = true, triggerSelf = true)
      nodesFut = nodes.mapIt(it.switch.start())

    await subscribeNodes(nodes)

    var seen: Table[string, int]
    var seenFut = newFuture[void]()
    for i in 0..<nodes.len:
      let dialer = nodes[i]
      var handler: TopicHandler
      closureScope:
        var peerName = $dialer.peerInfo.peerId
        handler = proc(topic: string, data: seq[byte]) {.async, gcsafe, closure.} =
          if peerName notin seen:
            seen[peerName] = 0
          seen[peerName].inc
          check topic == "foobar"
          if not seenFut.finished() and seen.len >= runs:
            seenFut.complete()

      dialer.subscribe("foobar", handler)
    await waitSubGraph(nodes, "foobar")

    tryPublish await wait(nodes[0].publish("foobar",
                                  toBytes("from node " &
                                  $nodes[0].peerInfo.peerId)),
                                  1.minutes), 1

    await wait(seenFut, 1.minutes)
    check: seen.len >= runs
    for k, v in seen.pairs:
      check: v >= 1

    for node in nodes:
      var gossip = GossipSub(node)

      check:
        "foobar" in gossip.gossipsub

    await allFuturesThrowing(
      nodes.mapIt(
        allFutures(
          it.switch.stop())))

    await allFuturesThrowing(nodesFut)

  asyncTest "e2e - GossipSub with multiple peers (sparse)":
    var runs = 10

    let
      nodes = generateNodes(runs, gossip = true, triggerSelf = true)
      nodesFut = nodes.mapIt(it.switch.start())

    await subscribeSparseNodes(nodes)

    var seen: Table[string, int]
    var seenFut = newFuture[void]()

    for i in 0..<nodes.len:
      let dialer = nodes[i]
      var handler: TopicHandler
      capture dialer, i:
        var peerName = $dialer.peerInfo.peerId
        handler = proc(topic: string, data: seq[byte]) {.async, gcsafe, closure.} =
          if peerName notin seen:
            seen[peerName] = 0
          seen[peerName].inc
          check topic == "foobar"
          if not seenFut.finished() and seen.len >= runs:
            seenFut.complete()

      dialer.subscribe("foobar", handler)

    await waitSubGraph(nodes, "foobar")
    tryPublish await wait(nodes[0].publish("foobar",
                                  toBytes("from node " &
                                  $nodes[0].peerInfo.peerId)),
                                  1.minutes), 1

    await wait(seenFut, 60.seconds)
    check: seen.len >= runs
    for k, v in seen.pairs:
      check: v >= 1

    for node in nodes:
      var gossip = GossipSub(node)
      check:
        "foobar" in gossip.gossipsub
        gossip.fanout.len == 0
        gossip.mesh["foobar"].len > 0

    await allFuturesThrowing(
      nodes.mapIt(
        allFutures(
          it.switch.stop())))

    await allFuturesThrowing(nodesFut)

  asyncTest "e2e - GossipSub peer exchange":
    # A, B & C are subscribed to something
    # B unsubcribe from it, it should send
    # PX to A & C
    #
    # C sent his SPR, not A
    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      discard # not used in this test

    let
      nodes = generateNodes(
        2,
        gossip = true,
        enablePX = true) &
        generateNodes(1, gossip = true, sendSignedPeerRecord = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(),
        nodes[1].switch.start(),
        nodes[2].switch.start(),
      )

    var
      gossip0 = GossipSub(nodes[0])
      gossip1 = GossipSub(nodes[1])
      gossip2 = GossipSub(nodes[1])

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)
    nodes[2].subscribe("foobar", handler)
    for x in 0..<3:
      for y in 0..<3:
        if x != y:
          await waitSub(nodes[x], nodes[y], "foobar")

    var passed: Future[void] = newFuture[void]()
    gossip0.routingRecordsHandler.add(proc(peer: PeerId, tag: string, peers: seq[RoutingRecordsPair]) =
      check:
        tag == "foobar"
        peers.len == 2
        peers[0].record.isSome() xor peers[1].record.isSome()
      passed.complete()
    )
    nodes[1].unsubscribe("foobar", handler)

    await passed.wait(5.seconds)

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop(),
      nodes[2].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

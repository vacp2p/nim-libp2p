## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.used.}

import sequtils, options, tables, sets
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

proc waitSub(sender, receiver: auto; key: string) {.async, gcsafe.} =
  if sender == receiver:
    return
  # turn things deterministic
  # this is for testing purposes only
  # peers can be inside `mesh` and `fanout`, not just `gossipsub`
  var ceil = 15
  let fsub = GossipSub(sender)
  let ev = newAsyncEvent()
  fsub.heartbeatEvents.add(ev)

  # await first heartbeat
  await ev.wait()
  ev.clear()

  while (not fsub.gossipsub.hasKey(key) or
         not fsub.gossipsub.hasPeerId(key, receiver.peerInfo.peerId)) and
        (not fsub.mesh.hasKey(key) or
         not fsub.mesh.hasPeerId(key, receiver.peerInfo.peerId)) and
        (not fsub.fanout.hasKey(key) or
         not fsub.fanout.hasPeerId(key , receiver.peerInfo.peerId)):
    trace "waitSub sleeping..."

    # await more heartbeats
    await ev.wait()
    ev.clear()

    dec ceil
    doAssert(ceil > 0, "waitSub timeout!")

template tryPublish(call: untyped, require: int, wait: Duration = 1.seconds, times: int = 10): untyped =
  var
    limit = times
    pubs = 0
  while pubs < require and limit > 0:
    pubs = pubs + call
    await sleepAsync(wait)
    limit.dec()
  if limit == 0:
    doAssert(false, "Failed to publish!")

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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

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

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    var subs: seq[Future[void]]
    subs &= waitSub(nodes[1], nodes[0], "foobar")
    subs &= waitSub(nodes[0], nodes[1], "foobar")

    await allFuturesThrowing(subs)

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

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    var subs: seq[Future[void]]
    subs &= waitSub(nodes[1], nodes[0], "foobar")
    subs &= waitSub(nodes[0], nodes[1], "foobar")

    await allFuturesThrowing(subs)

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

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

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

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

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

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

    await subscribeNodes(nodes)

    nodes[1].subscribe("foobar", handler)
    await sleepAsync(10.seconds)

    let gossip1 = GossipSub(nodes[0])
    let gossip2 = GossipSub(nodes[1])

    check:
      "foobar" in gossip2.topics
      "foobar" in gossip1.gossipsub
      gossip1.gossipsub.hasPeerId("foobar", gossip2.peerInfo.peerId)

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

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

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

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

    trace "test done, stopping..."

    await nodes[0].stop()
    await nodes[1].stop()

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

    await subscribeNodes(nodes)

    nodes[1].subscribe("foobar", handler)
    nodes[0].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")
    await waitSub(nodes[1], nodes[0], "foobar")

    nodes[0].unsubscribe("foobar", handler)

    let gsNode = GossipSub(nodes[1])
    check await checkExpiring(gsNode.mesh.getOrDefault("foobar").len == 0)

    nodes[0].subscribe("foobar", handler)

    check GossipSub(nodes[0]).mesh.getOrDefault("foobar").len == 0

    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check:
      GossipSub(nodes[0]).fanout.getOrDefault("foobar").len > 0
      GossipSub(nodes[0]).mesh.getOrDefault("foobar").len == 0

    await passed.wait(2.seconds)

    trace "test done, stopping..."

    await nodes[0].stop()
    await nodes[1].stop()

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

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

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub should not send to source & peers who already seen":
    # 3 nodes: A, B, C
    # A publishes, B relays, C is having a long validation
    # so C should not send to anyone

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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
        nodes[2].start(),
    ))

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
    await waitSub(nodes[0], nodes[1], "foobar")
    await waitSub(nodes[0], nodes[2], "foobar")
    await waitSub(nodes[2], nodes[1], "foobar")
    await waitSub(nodes[1], nodes[2], "foobar")

    var gossip1: GossipSub = GossipSub(nodes[0])
    var gossip2: GossipSub = GossipSub(nodes[1])
    var gossip3: GossipSub = GossipSub(nodes[2])

    proc slowValidator(topic: string, message: Message): Future[ValidationResult] {.async.} =
      await cRelayed
      # Empty A & C caches to detect duplicates
      gossip1.seen = TimedCache[MessageId].init()
      gossip3.seen = TimedCache[MessageId].init()
      let msgId = toSeq(gossip2.validationSeen.keys)[0]
      check await checkExpiring(try: gossip2.validationSeen[msgId].len > 0 except: false)
      result = ValidationResult.Accept
      bFinished.complete()

    nodes[1].addValidator("foobar", slowValidator)

    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    await bFinished

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop(),
      nodes[2].switch.stop()
    )

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop(),
      nodes[2].stop()
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

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

    var gossip1: GossipSub = GossipSub(nodes[0])
    gossip1.parameters.floodPublish = true
    var gossip2: GossipSub = GossipSub(nodes[1])
    gossip2.parameters.floodPublish = true

    await subscribeNodes(nodes)

    # nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)
    await waitSub(nodes[0], nodes[1], "foobar")

    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    check await passed

    check:
      "foobar" in gossip1.gossipsub
      "foobar" notin gossip2.gossipsub
      not gossip1.mesh.hasPeerId("foobar", gossip2.peerInfo.peerId)
      not gossip1.fanout.hasPeerId("foobar", gossip2.peerInfo.peerId)

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "e2e - GossipSub with multiple peers":
    var runs = 10

    let
      nodes = generateNodes(runs, gossip = true, triggerSelf = true)
      nodesFut = nodes.mapIt(it.switch.start())

    await allFuturesThrowing(nodes.mapIt(it.start()))
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
      await waitSub(nodes[0], dialer, "foobar")

    tryPublish await wait(nodes[0].publish("foobar",
                                  toBytes("from node " &
                                  $nodes[0].peerInfo.peerId)),
                                  1.minutes), 1, 5.seconds

    await wait(seenFut, 2.minutes)
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
          it.stop(),
          it.switch.stop())))

    await allFuturesThrowing(nodesFut)

  asyncTest "e2e - GossipSub with multiple peers (sparse)":
    var runs = 10

    let
      nodes = generateNodes(runs, gossip = true, triggerSelf = true)
      nodesFut = nodes.mapIt(it.switch.start())

    await allFuturesThrowing(nodes.mapIt(it.start()))
    await subscribeSparseNodes(nodes)

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
      await waitSub(nodes[0], dialer, "foobar")

    tryPublish await wait(nodes[0].publish("foobar",
                                  toBytes("from node " &
                                  $nodes[0].peerInfo.peerId)),
                                  1.minutes), 1, 5.seconds

    await wait(seenFut, 5.minutes)
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
          it.stop(),
          it.switch.stop())))

    await allFuturesThrowing(nodesFut)

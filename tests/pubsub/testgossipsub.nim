## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.used.}

import unittest, sequtils, options, tables, sets
import chronos, stew/byteutils
import chronicles
import utils, ../../libp2p/[errors,
                            peerid,
                            peerinfo,
                            stream/connection,
                            stream/bufferstream,
                            crypto/crypto,
                            protocols/pubsub/pubsub,
                            protocols/pubsub/pubsubpeer,
                            protocols/pubsub/gossipsub,
                            protocols/pubsub/peertable,
                            protocols/pubsub/rpc/messages]

import ../helpers

proc waitSub(sender, receiver: auto; key: string) {.async, gcsafe.} =
  if sender == receiver:
    return
  # turn things deterministic
  # this is for testing purposes only
  # peers can be inside `mesh` and `fanout`, not just `gossipsub`
  var ceil = 15
  let fsub = GossipSub(sender.pubSub.get())
  while (not fsub.gossipsub.hasKey(key) or
         not fsub.gossipsub.hasPeerID(key, receiver.peerInfo.id)) and
        (not fsub.mesh.hasKey(key) or
         not fsub.mesh.hasPeerID(key, receiver.peerInfo.id)) and
        (not fsub.fanout.hasKey(key) or
         not fsub.fanout.hasPeerID(key , receiver.peerInfo.id)):
    trace "waitSub sleeping..."
    await sleepAsync(1.seconds)
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
    for tracker in testTrackers():
      # echo tracker.dump()
      check tracker.isLeaked() == false

  test "GossipSub validation should succeed":
    proc runTests(): Future[bool] {.async.} =
      var handlerFut = newFuture[bool]()
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check topic == "foobar"
        handlerFut.complete(true)

      var nodes = generateNodes(2, true)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start()))
      awaiters.add((await nodes[1].start()))

      let subscribes = await subscribeNodes(nodes)

      await nodes[0].subscribe("foobar", handler)
      await nodes[1].subscribe("foobar", handler)

      var validatorFut = newFuture[bool]()
      proc validator(topic: string,
                     message: Message):
                     Future[bool] {.async.} =
        check topic == "foobar"
        validatorFut.complete(true)
        result = true

      nodes[1].addValidator("foobar", validator)
      tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

      result = (await validatorFut) and (await handlerFut)

      let gossip1 = GossipSub(nodes[0].pubSub.get())
      let gossip2 = GossipSub(nodes[1].pubSub.get())
      check:
        gossip1.mesh["foobar"].len == 1 and "foobar" notin gossip1.fanout
        gossip2.mesh["foobar"].len == 1 and "foobar" notin gossip2.fanout

      await allFuturesThrowing(
        nodes[0].stop(),
        nodes[1].stop())

      await allFuturesThrowing(subscribes)
      await allFuturesThrowing(awaiters)

    check:
      waitFor(runTests()) == true

  test "GossipSub validation should fail":
    proc runTests(): Future[bool] {.async.} =
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check false # if we get here, it should fail

      var nodes = generateNodes(2, true)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start()))
      awaiters.add((await nodes[1].start()))

      let subscribes = await subscribeNodes(nodes)

      await nodes[0].subscribe("foobar", handler)
      await nodes[1].subscribe("foobar", handler)

      var validatorFut = newFuture[bool]()
      proc validator(topic: string,
                     message: Message):
                     Future[bool] {.async.} =
        result = false
        validatorFut.complete(true)

      nodes[1].addValidator("foobar", validator)
      tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

      result = await validatorFut

      let gossip1 = GossipSub(nodes[0].pubSub.get())
      let gossip2 = GossipSub(nodes[1].pubSub.get())
      check:
        gossip1.mesh["foobar"].len == 1 and "foobar" notin gossip1.fanout
        gossip2.mesh["foobar"].len == 1 and "foobar" notin gossip2.fanout

      await allFuturesThrowing(
        nodes[0].stop(),
        nodes[1].stop())

      await allFuturesThrowing(subscribes)
      await allFuturesThrowing(awaiters)

    check:
      waitFor(runTests()) == true

  test "GossipSub validation one fails and one succeeds":
    proc runTests(): Future[bool] {.async.} =
      var handlerFut = newFuture[bool]()
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check topic == "foo"
        handlerFut.complete(true)

      var nodes = generateNodes(2, true)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start()))
      awaiters.add((await nodes[1].start()))

      let subscribes = await subscribeNodes(nodes)
      await nodes[1].subscribe("foo", handler)
      await nodes[1].subscribe("bar", handler)

      var passed, failed: Future[bool] = newFuture[bool]()
      proc validator(topic: string,
                     message: Message):
                     Future[bool] {.async.} =
        result = if topic == "foo":
          passed.complete(true)
          true
        else:
          failed.complete(true)
          false

      nodes[1].addValidator("foo", "bar", validator)
      tryPublish await nodes[0].publish("foo", "Hello!".toBytes()), 1
      tryPublish await nodes[0].publish("bar", "Hello!".toBytes()), 1

      result = ((await passed) and (await failed) and (await handlerFut))

      let gossip1 = GossipSub(nodes[0].pubSub.get())
      let gossip2 = GossipSub(nodes[1].pubSub.get())
      check:
        "foo" notin gossip1.mesh and gossip1.fanout["foo"].len == 1
        "foo" notin gossip2.mesh and "foo" notin gossip2.fanout
        "bar" notin gossip1.mesh and gossip1.fanout["bar"].len == 1
        "bar" notin gossip2.mesh and "bar" notin gossip2.fanout

      await allFuturesThrowing(
        nodes[0].stop(),
        nodes[1].stop())

      await allFuturesThrowing(subscribes)
      await allFuturesThrowing(awaiters)
      result = true
    check:
      waitFor(runTests()) == true

  test "GossipSub publish should fail on timeout":
    proc runTests(): Future[bool] {.async.} =
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        discard

      var nodes = generateNodes(2, gossip = true)
      var awaiters: seq[Future[void]]
      awaiters.add((await nodes[0].start()))
      awaiters.add((await nodes[1].start()))

      let subscribes = await subscribeNodes(nodes)
      await nodes[1].subscribe("foobar", handler)
      await waitSub(nodes[0], nodes[1], "foobar")

      let pubsub = nodes[0].pubSub.get()
      let peer = pubsub.peers[nodes[1].peerInfo.id]

      peer.conn = Connection(newBufferStream(
        proc (data: seq[byte]) {.async, gcsafe.} =
          await sleepAsync(10.seconds)
        , size = 0))

      let in10millis = Moment.fromNow(100.millis)
      let sent = await nodes[0].publish("foobar", "Hello!".toBytes(), 100.millis)

      check Moment.now() >= in10millis
      check sent == 0

      await allFuturesThrowing(
        nodes[0].stop(),
        nodes[1].stop())

      await allFuturesThrowing(subscribes)
      await allFuturesThrowing(awaiters)
      result = true

    check:
      waitFor(runTests()) == true

  test "e2e - GossipSub should add remote peer topic subscriptions":
    proc testBasicGossipSub(): Future[bool] {.async.} =
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        discard

      var nodes: seq[Switch] = newSeq[Switch]()
      for i in 0..<2:
        nodes.add newStandardSwitch(gossip = true,
                                    secureManagers = [SecureProtocol.Noise])

      var awaitters: seq[Future[void]]
      for node in nodes:
        awaitters.add(await node.start())

      let subscribes = await subscribeNodes(nodes)
      await nodes[1].subscribe("foobar", handler)
      await sleepAsync(10.seconds)

      let gossip1 = GossipSub(nodes[0].pubSub.get())
      let gossip2 = GossipSub(nodes[1].pubSub.get())

      check:
        "foobar" in gossip2.topics
        "foobar" in gossip1.gossipsub
        gossip1.gossipsub.hasPeerID("foobar", gossip2.peerInfo.id)

      await allFuturesThrowing(nodes.mapIt(it.stop()))

      await allFuturesThrowing(subscribes)
      await allFuturesThrowing(awaitters)

      result = true

    check:
      waitFor(testBasicGossipSub()) == true

  test "e2e - GossipSub should add remote peer topic subscriptions if both peers are subscribed":
    proc testBasicGossipSub(): Future[bool] {.async.} =
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        discard

      var nodes: seq[Switch] = newSeq[Switch]()
      for i in 0..<2:
        nodes.add newStandardSwitch(gossip = true, secureManagers = [SecureProtocol.Secio])

      var awaitters: seq[Future[void]]
      for node in nodes:
        awaitters.add(await node.start())

      let subscribes = await subscribeNodes(nodes)

      await nodes[0].subscribe("foobar", handler)
      await nodes[1].subscribe("foobar", handler)

      var subs: seq[Future[void]]
      subs &= waitSub(nodes[1], nodes[0], "foobar")
      subs &= waitSub(nodes[0], nodes[1], "foobar")

      await allFuturesThrowing(subs)

      let
        gossip1 = GossipSub(nodes[0].pubSub.get())
        gossip2 = GossipSub(nodes[1].pubSub.get())

      check:
        "foobar" in gossip1.topics
        "foobar" in gossip2.topics

        "foobar" in gossip1.gossipsub
        "foobar" in gossip2.gossipsub

        gossip1.gossipsub.hasPeerID("foobar", gossip2.peerInfo.id) or
        gossip1.mesh.hasPeerID("foobar", gossip2.peerInfo.id)

        gossip2.gossipsub.hasPeerID("foobar", gossip1.peerInfo.id) or
        gossip2.mesh.hasPeerID("foobar", gossip1.peerInfo.id)

      await allFuturesThrowing(nodes.mapIt(it.stop()))

      await allFuturesThrowing(subscribes)
      await allFuturesThrowing(awaitters)

      result = true

    check:
      waitFor(testBasicGossipSub()) == true

  test "e2e - GossipSub send over fanout A -> B":
    proc runTests(): Future[bool] {.async.} =
      var passed = newFuture[void]()
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check topic == "foobar"
        passed.complete()

      var nodes = generateNodes(2, true)
      var wait = newSeq[Future[void]]()
      wait.add(await nodes[0].start())
      wait.add(await nodes[1].start())

      let subscribes = await subscribeNodes(nodes)

      await nodes[1].subscribe("foobar", handler)
      await waitSub(nodes[0], nodes[1], "foobar")

      var observed = 0
      let
        obs1 = PubSubObserver(onRecv: proc(peer: PubSubPeer; msgs: var RPCMsg) =
          inc observed
        )
        obs2 = PubSubObserver(onSend: proc(peer: PubSubPeer; msgs: var RPCMsg) =
          inc observed
        )
      nodes[1].pubsub.get().addObserver(obs1)
      nodes[0].pubsub.get().addObserver(obs2)

      tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

      var gossip1: GossipSub = GossipSub(nodes[0].pubSub.get())
      var gossip2: GossipSub = GossipSub(nodes[1].pubSub.get())

      check:
        "foobar" in gossip1.gossipsub
        gossip1.fanout.hasPeerID("foobar", gossip2.peerInfo.id)
        not gossip1.mesh.hasPeerID("foobar", gossip2.peerInfo.id)

      await passed.wait(2.seconds)

      trace "test done, stopping..."

      await nodes[0].stop()
      await nodes[1].stop()

      await allFuturesThrowing(subscribes)
      await allFuturesThrowing(wait)

      check observed == 2
      result = true

    check:
      waitFor(runTests()) == true

  test "e2e - GossipSub send over mesh A -> B":
    proc runTests(): Future[bool] {.async.} =
      var passed: Future[bool] = newFuture[bool]()
      proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
        check topic == "foobar"
        passed.complete(true)

      var nodes = generateNodes(2, true)
      var wait: seq[Future[void]]
      wait.add(await nodes[0].start())
      wait.add(await nodes[1].start())

      let subscribes = await subscribeNodes(nodes)

      await nodes[0].subscribe("foobar", handler)
      await nodes[1].subscribe("foobar", handler)
      await waitSub(nodes[0], nodes[1], "foobar")

      tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

      result = await passed

      var gossip1: GossipSub = GossipSub(nodes[0].pubSub.get())
      var gossip2: GossipSub = GossipSub(nodes[1].pubSub.get())

      check:
        "foobar" in gossip1.gossipsub
        "foobar" in gossip2.gossipsub
        gossip1.mesh.hasPeerID("foobar", gossip2.peerInfo.id)
        not gossip1.fanout.hasPeerID("foobar", gossip2.peerInfo.id)
        gossip2.mesh.hasPeerID("foobar", gossip1.peerInfo.id)
        not gossip2.fanout.hasPeerID("foobar", gossip1.peerInfo.id)

      await nodes[0].stop()
      await nodes[1].stop()

      await allFuturesThrowing(subscribes)
      await allFuturesThrowing(wait)

    check:
      waitFor(runTests()) == true

  test "e2e - GossipSub with multiple peers":
    proc runTests(): Future[bool] {.async.} =
      var nodes: seq[Switch] = newSeq[Switch]()
      var awaitters: seq[Future[void]]
      var runs = 10

      for i in 0..<runs:
        nodes.add newStandardSwitch(triggerSelf = true,
                                    gossip = true,
                                    secureManagers = [SecureProtocol.Noise])
        awaitters.add((await nodes[i].start()))

      let subscribes = await subscribeRandom(nodes)

      var seen: Table[string, int]
      var subs: seq[Future[void]]
      var seenFut = newFuture[void]()
      for dialer in nodes:
        var handler: TopicHandler
        closureScope:
          var dialerNode = dialer
          handler = proc(topic: string, data: seq[byte]) {.async, gcsafe, closure.} =
            if dialerNode.peerInfo.id notin seen:
              seen[dialerNode.peerInfo.id] = 0
            seen[dialerNode.peerInfo.id].inc
            check topic == "foobar"
            if not seenFut.finished() and seen.len >= runs:
              seenFut.complete()

        subs &= dialer.subscribe("foobar", handler)

      await allFuturesThrowing(subs)

      tryPublish await wait(nodes[0].publish("foobar",
                                    cast[seq[byte]]("from node " &
                                    nodes[1].peerInfo.id)),
                                    1.minutes), runs, 5.seconds

      await wait(seenFut, 2.minutes)
      check: seen.len >= runs
      for k, v in seen.pairs:
        check: v >= 1

      for node in nodes:
        var gossip: GossipSub = GossipSub(node.pubSub.get())
        check:
          "foobar" in gossip.gossipsub
          gossip.fanout.len == 0
          gossip.mesh["foobar"].len > 0

      await allFuturesThrowing(nodes.mapIt(it.stop()))

      await allFuturesThrowing(subscribes)
      await allFuturesThrowing(awaitters)
      result = true

    check:
      waitFor(runTests()) == true

  test "e2e - GossipSub with multiple peers (sparse)":
    proc runTests(): Future[bool] {.async.} =
      var nodes: seq[Switch] = newSeq[Switch]()
      var awaitters: seq[Future[void]]
      var runs = 10

      for i in 0..<runs:
        nodes.add newStandardSwitch(triggerSelf = true,
                                    gossip = true,
                                    secureManagers = [SecureProtocol.Secio])
        awaitters.add((await nodes[i].start()))

      let subscribes = await subscribeSparseNodes(nodes, 1)

      var seen: Table[string, int]
      var subs: seq[Future[void]]
      var seenFut = newFuture[void]()
      for dialer in nodes:
        var handler: TopicHandler
        closureScope:
          var dialerNode = dialer
          handler = proc(topic: string, data: seq[byte])
            {.async, gcsafe, closure.} =
            if dialerNode.peerInfo.id notin seen:
              seen[dialerNode.peerInfo.id] = 0
            seen[dialerNode.peerInfo.id].inc
            check topic == "foobar"
            if not seenFut.finished() and seen.len >= runs:
              seenFut.complete()

        subs &= dialer.subscribe("foobar", handler)

      await allFuturesThrowing(subs)

      tryPublish await wait(nodes[0].publish("foobar",
                                    cast[seq[byte]]("from node " &
                                    nodes[1].peerInfo.id)),
                                    1.minutes), 2, 5.seconds

      await wait(seenFut, 5.minutes)
      check: seen.len >= runs
      for k, v in seen.pairs:
        check: v >= 1

      for node in nodes:
        var gossip: GossipSub = GossipSub(node.pubSub.get())
        check:
          "foobar" in gossip.gossipsub
          gossip.fanout.len == 0
          gossip.mesh["foobar"].len > 0

      await allFuturesThrowing(nodes.mapIt(it.stop()))

      await allFuturesThrowing(subscribes)
      await allFuturesThrowing(awaitters)
      result = true

    check:
      waitFor(runTests()) == true

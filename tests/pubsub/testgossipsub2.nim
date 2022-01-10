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
                            protocols/pubsub/rpc/messages]
import ../helpers

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

  asyncTest "e2e - GossipSub with multiple peers - control deliver (sparse)":
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
      let dgossip = GossipSub(dialer)
      dgossip.parameters.dHigh = 2
      dgossip.parameters.dLow = 1
      dgossip.parameters.d = 1
      dgossip.parameters.dOut = 1
      var handler: TopicHandler
      closureScope:
        var peerName = $dialer.peerInfo.peerId
        handler = proc(topic: string, data: seq[byte]) {.async, gcsafe, closure.} =
          if peerName notin seen:
            seen[peerName] = 0
          seen[peerName].inc
          info "seen up", count=seen.len
          check topic == "foobar"
          if not seenFut.finished() and seen.len >= runs:
            seenFut.complete()

      dialer.subscribe("foobar", handler)
      await waitSub(nodes[0], dialer, "foobar")

    # we want to test ping pong deliveries via control Iwant/Ihave, so we publish just in a tap
    let publishedTo = nodes[0]
      .publish("foobar", toBytes("from node " & $nodes[0].peerInfo.peerId))
      .await
    check:
      publishedTo != 0
      publishedTo != runs

    await wait(seenFut, 5.minutes)
    check: seen.len >= runs
    for k, v in seen.pairs:
      check: v >= 1

    await allFuturesThrowing(
      nodes.mapIt(
        allFutures(
          it.stop(),
          it.switch.stop())))

    await allFuturesThrowing(nodesFut)

  asyncTest "GossipSub invalid topic subscription":
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

    # We must subscribe before setting the validator
    nodes[0].subscribe("foobar", handler)

    var gossip = GossipSub(nodes[0])
    let invalidDetected = newFuture[void]()
    gossip.subscriptionValidator =
      proc(topic: string): bool =
        if topic == "foobar":
          try:
            invalidDetected.complete()
          except:
            raise newException(Defect, "Exception during subscriptionValidator")
          false
        else:
          true

    await subscribeNodes(nodes)

    nodes[1].subscribe("foobar", handler)

    await invalidDetected.wait(10.seconds)

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub test directPeers":
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

    var gossip = GossipSub(nodes[0])
    gossip.parameters.directPeers[nodes[1].switch.peerInfo.peerId] = nodes[1].switch.peerInfo.addrs

    # start pubsub
    await allFuturesThrowing(
      allFinished(
        nodes[0].start(),
        nodes[1].start(),
    ))

    let invalidDetected = newFuture[void]()
    gossip.subscriptionValidator =
      proc(topic: string): bool =
        if topic == "foobar":
          try:
            invalidDetected.complete()
          except:
            raise newException(Defect, "Exception during subscriptionValidator")
          false
        else:
          true

    # DO NOT SUBSCRIBE, CONNECTION SHOULD HAPPEN
    ### await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    await invalidDetected.wait(10.seconds)

    await allFuturesThrowing(
      nodes[0].switch.stop(),
      nodes[1].switch.stop()
    )

    await allFuturesThrowing(
      nodes[0].stop(),
      nodes[1].stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipsSub peers disconnections mechanics":
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

    # ensure peer stats are stored properly and kept properly
    check:
      GossipSub(nodes[0]).peerStats.len == runs - 1 # minus self

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

    # Removing some subscriptions

    for i in 0..<runs:
      if i mod 3 != 0:
        nodes[i].unsubscribeAll("foobar")

    # Waiting 2 heartbeats

    for _ in 0..1:
      for i in 0..<runs:
        if i mod 3 == 0:
          let evnt = newAsyncEvent()
          GossipSub(nodes[i]).heartbeatEvents &= evnt
          await evnt.wait()

    # ensure peer stats are stored properly and kept properly
    check:
      GossipSub(nodes[0]).peerStats.len == runs - 1 # minus self

    # Adding again subscriptions

    proc handler(topic: string, data: seq[byte]) {.async, gcsafe.} =
      check topic == "foobar"

    for i in 0..<runs:
      if i mod 3 != 0:
        nodes[i].subscribe("foobar", handler)

    # Waiting 2 heartbeats

    for _ in 0..1:
      for i in 0..<runs:
        if i mod 3 == 0:
          let evnt = newAsyncEvent()
          GossipSub(nodes[i]).heartbeatEvents &= evnt
          await evnt.wait()

    # ensure peer stats are stored properly and kept properly
    check:
      GossipSub(nodes[0]).peerStats.len == runs - 1 # minus self

    await allFuturesThrowing(
      nodes.mapIt(
        allFutures(
          it.stop(),
          it.switch.stop())))

    await allFuturesThrowing(nodesFut)

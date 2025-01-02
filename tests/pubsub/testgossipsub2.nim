# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import sequtils, options, tables, sets
import chronos, stew/byteutils, chronicles
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
    protocols/pubsub/pubsubpeer,
    protocols/pubsub/peertable,
    protocols/pubsub/rpc/messages,
  ]
import ../helpers

template tryPublish(
    call: untyped, require: int, wait = 10.milliseconds, timeout = 10.seconds
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

  asyncTest "e2e - GossipSub with multiple peers - control deliver (sparse)":
    var runs = 10

    let
      nodes = generateNodes(runs, gossip = true, triggerSelf = true)
      nodesFut = nodes.mapIt(it.switch.start())

    await subscribeSparseNodes(nodes)

    var seen: Table[string, int]
    var seenFut = newFuture[void]()
    for i in 0 ..< nodes.len:
      let dialer = nodes[i]
      let dgossip = GossipSub(dialer)
      dgossip.parameters.dHigh = 2
      dgossip.parameters.dLow = 1
      dgossip.parameters.d = 1
      dgossip.parameters.dOut = 1
      var handler: TopicHandler
      closureScope:
        var peerName = $dialer.peerInfo.peerId
        handler = proc(
            topic: string, data: seq[byte]
        ) {.async: (raises: []), closure.} =
          try:
            if peerName notin seen:
              seen[peerName] = 0
            seen[peerName].inc
          except KeyError:
            raiseAssert "seen checked before"
          info "seen up", count = seen.len
          check topic == "foobar"
          if not seenFut.finished() and seen.len >= runs:
            seenFut.complete()

      dialer.subscribe("foobar", handler)
      await waitSub(nodes[0], dialer, "foobar")

    # we want to test ping pong deliveries via control Iwant/Ihave, so we publish just in a tap
    let publishedTo = nodes[0].publish(
      "foobar", toBytes("from node " & $nodes[0].peerInfo.peerId)
    ).await
    check:
      publishedTo != 0
      publishedTo != runs

    await wait(seenFut, 5.minutes)
    check:
      seen.len >= runs
    for k, v in seen.pairs:
      check:
        v >= 1

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

    await allFuturesThrowing(nodesFut)

  asyncTest "GossipSub invalid topic subscription":
    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async: (raises: []).} =
      check topic == "foobar"
      handlerFut.complete(true)

    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    # We must subscribe before setting the validator
    nodes[0].subscribe("foobar", handler)

    var gossip = GossipSub(nodes[0])
    let invalidDetected = newFuture[void]()
    gossip.subscriptionValidator = proc(topic: string): bool =
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

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub test directPeers":
    let nodes = generateNodes(2, gossip = true)
    await allFutures(nodes[0].switch.start(), nodes[1].switch.start())
    await GossipSub(nodes[0]).addDirectPeer(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )

    let invalidDetected = newFuture[void]()
    GossipSub(nodes[0]).subscriptionValidator = proc(topic: string): bool =
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

    proc handler(topic: string, data: seq[byte]) {.async: (raises: []).} =
      discard

    nodes[1].subscribe("foobar", handler)

    await invalidDetected.wait(10.seconds)

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

  asyncTest "GossipSub directPeers: always forward messages":
    let
      nodes = generateNodes(3, gossip = true)

      # start switches
      nodesFut = await allFinished(
        nodes[0].switch.start(), nodes[1].switch.start(), nodes[2].switch.start()
      )

    await GossipSub(nodes[0]).addDirectPeer(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )
    await GossipSub(nodes[1]).addDirectPeer(
      nodes[0].switch.peerInfo.peerId, nodes[0].switch.peerInfo.addrs
    )
    await GossipSub(nodes[1]).addDirectPeer(
      nodes[2].switch.peerInfo.peerId, nodes[2].switch.peerInfo.addrs
    )
    await GossipSub(nodes[2]).addDirectPeer(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )

    var handlerFut = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async: (raises: []).} =
      check topic == "foobar"
      handlerFut.complete()

    proc noop(topic: string, data: seq[byte]) {.async: (raises: []).} =
      check topic == "foobar"

    nodes[0].subscribe("foobar", noop)
    nodes[1].subscribe("foobar", noop)
    nodes[2].subscribe("foobar", handler)

    tryPublish await nodes[0].publish("foobar", toBytes("hellow")), 1

    await handlerFut.wait(2.seconds)

    # peer shouldn't be in our mesh
    check "foobar" notin GossipSub(nodes[0]).mesh
    check "foobar" notin GossipSub(nodes[1]).mesh
    check "foobar" notin GossipSub(nodes[2]).mesh

    await allFuturesThrowing(
      nodes[0].switch.stop(), nodes[1].switch.stop(), nodes[2].switch.stop()
    )

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub directPeers: don't kick direct peer with low score":
    let
      nodes = generateNodes(2, gossip = true)

      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    await GossipSub(nodes[0]).addDirectPeer(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )
    await GossipSub(nodes[1]).addDirectPeer(
      nodes[0].switch.peerInfo.peerId, nodes[0].switch.peerInfo.addrs
    )

    GossipSub(nodes[1]).parameters.disconnectBadPeers = true
    GossipSub(nodes[1]).parameters.graylistThreshold = 100000

    var handlerFut = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async: (raises: []).} =
      check topic == "foobar"
      handlerFut.complete()

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    tryPublish await nodes[0].publish("foobar", toBytes("hellow")), 1

    await handlerFut

    GossipSub(nodes[1]).updateScores()
    # peer shouldn't be in our mesh
    check:
      GossipSub(nodes[1]).peerStats[nodes[0].switch.peerInfo.peerId].score <
        GossipSub(nodes[1]).parameters.graylistThreshold
    GossipSub(nodes[1]).updateScores()

    handlerFut = newFuture[void]()
    tryPublish await nodes[0].publish("foobar", toBytes("hellow2")), 1

    # Without directPeers, this would fail
    await handlerFut.wait(1.seconds)

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

  asyncTest "GossipSub peers disconnections mechanics":
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
        handler = proc(
            topic: string, data: seq[byte]
        ) {.async: (raises: []), closure.} =
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

    # ensure peer stats are stored properly and kept properly
    check:
      GossipSub(nodes[0]).peerStats.len == runs - 1 # minus self

    tryPublish await wait(
      nodes[0].publish("foobar", toBytes("from node " & $nodes[0].peerInfo.peerId)),
      1.minutes,
    ), 1, 5.seconds, 3.minutes

    await wait(seenFut, 5.minutes)
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

    # Removing some subscriptions

    for i in 0 ..< runs:
      if i mod 3 != 0:
        nodes[i].unsubscribeAll("foobar")

    # Waiting 2 heartbeats

    for _ in 0 .. 1:
      let evnt = newAsyncEvent()
      GossipSub(nodes[0]).heartbeatEvents &= evnt
      await evnt.wait()

    # ensure peer stats are stored properly and kept properly
    check:
      GossipSub(nodes[0]).peerStats.len == runs - 1 # minus self

    # Adding again subscriptions

    proc handler(topic: string, data: seq[byte]) {.async: (raises: []).} =
      check topic == "foobar"

    for i in 0 ..< runs:
      if i mod 3 != 0:
        nodes[i].subscribe("foobar", handler)

    # Waiting 2 heartbeats

    for _ in 0 .. 1:
      let evnt = newAsyncEvent()
      GossipSub(nodes[0]).heartbeatEvents &= evnt
      await evnt.wait()

    # ensure peer stats are stored properly and kept properly
    check:
      GossipSub(nodes[0]).peerStats.len == runs - 1 # minus self

    await allFuturesThrowing(nodes.mapIt(allFutures(it.switch.stop())))

    await allFuturesThrowing(nodesFut)

  asyncTest "GossipSub scoring - decayInterval":
    let nodes = generateNodes(2, gossip = true)

    var gossip = GossipSub(nodes[0])
    # MacOs has some nasty jitter when sleeping
    # (up to 7 ms), so we need some pretty long
    # sleeps to be safe here
    gossip.parameters.decayInterval = 300.milliseconds

    let
      # start switches
      nodesFut = await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

    var handlerFut = newFuture[void]()
    proc handler(topic: string, data: seq[byte]) {.async: (raises: []).} =
      handlerFut.complete()

    await subscribeNodes(nodes)

    nodes[0].subscribe("foobar", handler)
    nodes[1].subscribe("foobar", handler)

    tryPublish await nodes[0].publish("foobar", toBytes("hello")), 1

    await handlerFut

    gossip.peerStats[nodes[1].peerInfo.peerId].topicInfos["foobar"].meshMessageDeliveries =
      100
    gossip.topicParams["foobar"].meshMessageDeliveriesDecay = 0.9
    await sleepAsync(1500.milliseconds)

    # We should have decayed 5 times, though allowing 4..6
    check:
      gossip.peerStats[nodes[1].peerInfo.peerId].topicInfos["foobar"].meshMessageDeliveries in
        50.0 .. 66.0

    await allFuturesThrowing(nodes[0].switch.stop(), nodes[1].switch.stop())

    await allFuturesThrowing(nodesFut.concat())

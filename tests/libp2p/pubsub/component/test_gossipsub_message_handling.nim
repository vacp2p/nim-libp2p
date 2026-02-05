# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, std/[sequtils, enumerate], stew/byteutils, sugar, chronicles
import
  ../../../../libp2p/protocols/pubsub/
    [gossipsub, mcache, peertable, timedcache, rpc/message]
import ../../../tools/[lifecycle, topology, unittest, futures, sync]
import ../utils

const MsgIdSuccess = "msg id gen success"

proc setupTest(
    topic: string
): Future[
    tuple[
      gossip0: GossipSub, gossip1: GossipSub, receivedMessages: ref HashSet[seq[byte]]
    ]
] {.async.} =
  let nodes = generateNodes(
      2,
      gossip = true,
      verifySignature = false,
      historyLength = 100,
        # has to be larger, as otherwise history will get cleared if 
        #requests don't get in time
    )
    .toGossipSub()
  await startNodes(nodes)

  await connectNodesStar(nodes)

  var receivedMessages = new(HashSet[seq[byte]])

  proc handlerA(topic: string, data: seq[byte]) {.async.} =
    receivedMessages[].incl(data)

  proc handlerB(topic: string, data: seq[byte]) {.async.} =
    raiseAssert "should not be called"

  nodes[0].subscribe(topic, handlerA)
  nodes[1].subscribe(topic, handlerB)
  waitSubscribeStar(nodes, topic)

  return (nodes[0], nodes[1], receivedMessages)

proc teardownTest(gossip0: GossipSub, gossip1: GossipSub) {.async.} =
  await stopNodes(@[gossip0, gossip1])

proc createMessages(
    gossip0: GossipSub, gossip1: GossipSub, topic: string, size1: int, size2: int
): tuple[iwantMessageIds: seq[MessageId], sentMessages: HashSet[seq[byte]]] =
  var iwantMessageIds = newSeq[MessageId]()
  var sentMessages = initHashSet[seq[byte]]()

  for i, size in enumerate([size1, size2]):
    let data = newSeqWith(size, i.byte)
    sentMessages.incl(data)

    let msg = Message.init(gossip1.peerInfo.peerId, data, topic, some(uint64(i + 1)))
    let iwantMessageId = gossip1.msgIdProvider(msg).expect(MsgIdSuccess)
    iwantMessageIds.add(iwantMessageId)
    gossip1.mcache.put(iwantMessageId, msg)

    let peer = gossip1.peers[(gossip0.peerInfo.peerId)]
    peer.sentIHaves[^1].incl(iwantMessageId)

  return (iwantMessageIds, sentMessages)

suite "GossipSub Component - Message Handling":
  const topic = "foobar"

  teardown:
    checkTrackers()

  asyncTest "Split IWANT replies when individual messages are below maxSize but combined exceed maxSize":
    # This test checks if two messages, each below the maxSize, are correctly split when their combined size exceeds maxSize.
    # Expected: Both messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest(topic)
    defer:
      await teardownTest(gossip0, gossip1)

    let messageSize = gossip1.maxMessageSize div 2 + 1
    let (iwantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, topic, messageSize, messageSize)

    gossip1.broadcast(
      gossip1.mesh[topic],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: topic, messageIDs: iwantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    checkUntilTimeout:
      receivedMessages[] == sentMessages

  asyncTest "Discard IWANT replies when both messages individually exceed maxSize":
    # This test checks if two messages, each exceeding the maxSize, are discarded and not sent.
    # Expected: No messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest(topic)
    defer:
      await teardownTest(gossip0, gossip1)

    let messageSize = gossip1.maxMessageSize + 10
    let (bigIWantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, topic, messageSize, messageSize)

    gossip1.broadcast(
      gossip1.mesh[topic],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: topic, messageIDs: bigIWantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    # wait some time before asserting that messages is not received
    await sleepAsync(500.milliseconds)

    check:
      receivedMessages[].len == 0

  asyncTest "Process IWANT replies when both messages are below maxSize":
    # This test checks if two messages, both below the maxSize, are correctly processed and sent.
    # Expected: Both messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest(topic)
    defer:
      await teardownTest(gossip0, gossip1)
    let size1 = gossip1.maxMessageSize div 2
    let size2 = gossip1.maxMessageSize div 3
    let (bigIWantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, topic, size1, size2)

    gossip1.broadcast(
      gossip1.mesh[topic],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: topic, messageIDs: bigIWantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    checkUntilTimeout:
      receivedMessages[] == sentMessages

  asyncTest "Split IWANT replies when one message is below maxSize and the other exceeds maxSize":
    # This test checks if, when given two messages where one is below maxSize and the other exceeds it, only the smaller message is processed and sent.
    # Expected: Only the smaller message should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest(topic)
    defer:
      await teardownTest(gossip0, gossip1)
    let maxSize = gossip1.maxMessageSize
    let size1 = maxSize div 2
    let size2 = maxSize + 10
    let (bigIWantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, topic, size1, size2)

    gossip1.broadcast(
      gossip1.mesh[topic],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: topic, messageIDs: bigIWantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    var smallestSet: HashSet[seq[byte]]
    let seqs = toSeq(sentMessages)
    if seqs[0].len < seqs[1].len:
      smallestSet.incl(seqs[0])
    else:
      smallestSet.incl(seqs[1])

    checkUntilTimeout:
      receivedMessages[] == smallestSet

  asyncTest "messages are not sent back to source or forwarding peer":
    let
      numberOfNodes = 3
      nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    let (handlerFut0, handler0) = createCompleteHandler()
    let (handlerFut1, handler1) = createCompleteHandler()
    let (handlerFut2, handler2) = createCompleteHandler()

    # Nodes are connected in a ring
    await connectNodesRing(nodes)

    # And subscribed to the same topic
    subscribeAllNodes(nodes, topic, @[handler0, handler1, handler2])
    waitSubscribeRing(nodes, topic)

    # When node 0 sends a message
    check (await nodes[0].publish(topic, "Hello!".toBytes())) == 2

    # Nodes 1 and 2 should receive the message, but node 0 shouldn't receive it back
    checkUntilTimeout:
      handlerFut0.finished() == false
      handlerFut1.finished() == true
      handlerFut2.finished() == true

  asyncTest "GossipSub validation should succeed":
    var handlerFut = newFuture[bool]()
    proc handler(handlerTopic: string, data: seq[byte]) {.async.} =
      check handlerTopic == topic
      handlerFut.complete(true)

    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, handler)
    waitSubscribeStar(nodes, topic)

    var validatorFut = newFuture[bool]()
    proc validator(
        validatorTopic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      check validatorTopic == topic
      validatorFut.complete(true)
      result = ValidationResult.Accept

    nodes[1].addValidator(topic, validator)
    tryPublish await nodes[0].publish(topic, "Hello!".toBytes()), 1

    check (await validatorFut) and (await handlerFut)

  asyncTest "GossipSub validation should fail (reject)":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      raiseAssert "Handler should not be called when validation rejects message"

    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, handler)
    waitSubscribeStar(nodes, topic)

    check:
      nodes[0].mesh[topic].len == 1 and topic notin nodes[0].fanout
      nodes[1].mesh[topic].len == 1 and topic notin nodes[1].fanout

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      result = ValidationResult.Reject
      validatorFut.complete(true)

    nodes[1].addValidator(topic, validator)
    tryPublish await nodes[0].publish(topic, "Hello!".toBytes()), 1

    check (await validatorFut) == true

  asyncTest "GossipSub validation should fail (ignore)":
    proc handler(topic: string, data: seq[byte]) {.async.} =
      raiseAssert "Handler should not be called when validation ignores message"

    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, handler)
    waitSubscribeStar(nodes, topic)

    check:
      nodes[0].mesh[topic].len == 1 and topic notin nodes[0].fanout
      nodes[1].mesh[topic].len == 1 and topic notin nodes[1].fanout

    var validatorFut = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      result = ValidationResult.Ignore
      validatorFut.complete(true)

    nodes[1].addValidator(topic, validator)
    tryPublish await nodes[0].publish(topic, "Hello!".toBytes()), 1

    check (await validatorFut) == true

  asyncTest "GossipSub validation one fails and one succeeds":
    const
      topicFoo = "foo"
      topicBar = "bar"

    var handlerFut = newFuture[bool]()
    proc handler(topic: string, data: seq[byte]) {.async.} =
      check topic == topicFoo
      handlerFut.complete(true)

    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topicFoo, handler)
    nodes[1].subscribe(topicBar, handler)

    var passed, failed: Future[bool] = newFuture[bool]()
    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      result =
        if topic == topicFoo:
          passed.complete(true)
          ValidationResult.Accept
        else:
          failed.complete(true)
          ValidationResult.Reject

    nodes[1].addValidator(topicFoo, topicBar, validator)
    tryPublish await nodes[0].publish(topicFoo, "Hello!".toBytes()), 1
    tryPublish await nodes[0].publish(topicBar, "Hello!".toBytes()), 1

    check ((await passed) and (await failed) and (await handlerFut))

    check:
      topicFoo notin nodes[0].mesh and nodes[0].fanout[topicFoo].len == 1
      topicFoo notin nodes[1].mesh and topicFoo notin nodes[1].fanout
      topicBar notin nodes[0].mesh and nodes[0].fanout[topicBar].len == 1
      topicBar notin nodes[1].mesh and topicBar notin nodes[1].fanout

  asyncTest "GossipSub's observers should run after message is sent, received and validated":
    const
      topicFoo = "foo"
      topicBar = "bar"
    var
      recvCounter = 0
      sendCounter = 0
      validatedCounter = 0

    proc onRecv(peer: PubSubPeer, msgs: var RPCMsg) =
      inc recvCounter

    proc onSend(peer: PubSubPeer, msgs: var RPCMsg) =
      inc sendCounter

    proc onValidated(peer: PubSubPeer, msg: Message, msgId: MessageId) =
      inc validatedCounter

    let obs0 = PubSubObserver(onSend: onSend)
    let obs1 = PubSubObserver(onRecv: onRecv, onValidated: onValidated)

    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[0].addObserver(obs0)
    nodes[1].addObserver(obs1)
    nodes[1].subscribe(topicFoo, voidTopicHandler)
    nodes[1].subscribe(topicBar, voidTopicHandler)
    waitSubscribe(nodes[0], nodes[1], topicFoo)
    waitSubscribe(nodes[0], nodes[1], topicBar)

    proc validator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      result =
        if topic == topicFoo: ValidationResult.Accept else: ValidationResult.Reject

    nodes[1].addValidator(topicFoo, topicBar, validator)

    # Send message that will be accepted by the receiver's validator
    tryPublish await nodes[0].publish(topicFoo, "Hello!".toBytes()), 1

    checkUntilTimeout:
      recvCounter == 1
      validatedCounter == 1
      sendCounter == 1

    # Send message that will be rejected by the receiver's validator
    tryPublish await nodes[0].publish(topicBar, "Hello!".toBytes()), 1

    checkUntilTimeout:
      recvCounter == 2
      validatedCounter == 1
      sendCounter == 2

  asyncTest "GossipSub send over mesh A -> B":
    var passed: Future[bool] = newFuture[bool]()
    proc handler(handlerTopic: string, data: seq[byte]) {.async.} =
      check handlerTopic == topic
      passed.complete(true)

    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    subscribeAllNodes(nodes, topic, handler)
    waitSubscribeStar(nodes, topic)

    tryPublish await nodes[0].publish(topic, "Hello!".toBytes()), 1

    check await passed

    check:
      topic in nodes[0].gossipsub
      topic in nodes[1].gossipsub
      nodes[0].mesh.hasPeerId(topic, nodes[1].peerInfo.peerId)
      not nodes[0].fanout.hasPeerId(topic, nodes[1].peerInfo.peerId)
      nodes[1].mesh.hasPeerId(topic, nodes[0].peerInfo.peerId)
      not nodes[1].fanout.hasPeerId(topic, nodes[0].peerInfo.peerId)

  asyncTest "GossipSub should not send to source & peers who already seen":
    # 3 nodes: A, B, C
    # A publishes, C relays, B is having a long validation
    # so B should not send to anyone
    let nodes = generateNodes(3, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    let cRelayed = newWaitGroup(1)
    let bFinished = newWaitGroup(1)
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
      cRelayed.done()

    nodes[0].subscribe(topic, handlerA)
    nodes[1].subscribe(topic, handlerB)
    nodes[2].subscribe(topic, handlerC)
    waitSubscribeStar(nodes, topic)

    proc slowValidator(
        topic: string, message: Message
    ): Future[ValidationResult] {.async.} =
      try:
        await cRelayed.wait()
        # Empty A & C caches to detect duplicates
        nodes[0].seen = TimedCache[SaltedId].init()
        nodes[2].seen = TimedCache[SaltedId].init()
        let msgId = toSeq(nodes[1].validationSeen.keys)[0]
        checkUntilTimeout(
          try:
            nodes[1].validationSeen[msgId].len > 0
          except KeyError:
            false
        )
        result = ValidationResult.Accept
        bFinished.done()
      except CancelledError:
        raiseAssert "err on slowValidator"

    nodes[1].addValidator(topic, slowValidator)

    checkUntilTimeout:
      nodes[0].mesh.getOrDefault(topic).len == 2
      nodes[1].mesh.getOrDefault(topic).len == 2
      nodes[2].mesh.getOrDefault(topic).len == 2
    tryPublish await nodes[0].publish(topic, "Hello!".toBytes()), 2

    await bFinished.wait()

  asyncTest "GossipSub send over floodPublish A -> B":
    var passed: Future[bool] = newFuture[bool]()
    proc handler(handlerTopic: string, data: seq[byte]) {.async.} =
      check handlerTopic == topic
      passed.complete(true)

    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    nodes[0].parameters.floodPublish = true
    nodes[1].parameters.floodPublish = true

    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, handler)
    waitSubscribe(nodes[0], nodes[1], topic)

    tryPublish await nodes[0].publish(topic, "Hello!".toBytes()), 1

    check await passed.wait(10.seconds)

    check:
      topic in nodes[0].gossipsub
      topic notin nodes[1].gossipsub
      not nodes[0].mesh.hasPeerId(topic, nodes[1].peerInfo.peerId)

  asyncTest "GossipSub floodPublish with bandwidthEstimatebps":
    let nodes = generateNodes(
        20,
        gossip = true,
        transport = TransportType.TCP, # use TCP becasue it's more reliable (temporarily)
      )
      .toGossipSub()

    nodes[0].parameters.floodPublish = true
    nodes[0].parameters.bandwidthEstimatebps = 100_000_000
    # bandwidth is calculated per heartbeat
    nodes[0].parameters.heartbeatInterval = milliseconds(700)

    startNodesAndDeferStop(nodes)
    await connectNodesHub(nodes[0], nodes[1 ..^ 1])

    subscribeAllNodes(nodes, topic, voidTopicHandler)
    waitSubscribeHub(nodes[0], nodes[1 .. ^1], topic)

    # before publishing messages, wait for begining of Node0 heartbeat interval
    # to make sure that all publications are made within same heartbeat. 
    await nodes[0].waitForNextHeartbeat()
    check (await nodes[0].publish(topic, newSeq[byte](2_500_000))) == 12

    # do it again but with smaller message, and expect to be deliver to more nodes, 
    # then the first message. that's because second message is smaller then the first.
    await nodes[0].waitForNextHeartbeat()
    check (await nodes[0].publish(topic, newSeq[byte](500_001))) == 17

  asyncTest "GossipSub floodPublish limit without bandwidthEstimatebps":
    let nodes = generateNodes(20, gossip = true).toGossipSub()

    nodes[0].parameters.floodPublish = true
    # should flood publish to all, when bandwidthEstimatebps is disabled
    nodes[0].parameters.bandwidthEstimatebps = 0

    startNodesAndDeferStop(nodes)
    await connectNodesHub(nodes[0], nodes[1 ..^ 1])

    subscribeAllNodes(nodes, topic, voidTopicHandler)
    waitSubscribeHub(nodes[0], nodes[1 .. ^1], topic)

    # should publish to all nodes with bandwidthEstimatebps disabled
    check (await nodes[0].publish(topic, newSeq[byte](2_500_000))) == nodes.len - 1
    check (await nodes[0].publish(topic, newSeq[byte](500_001))) == nodes.len - 1

  asyncTest "GossipSub with multiple peers":
    const numberOfNodes = 10

    let nodes =
      generateNodes(numberOfNodes, gossip = true, triggerSelf = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    var seen: Table[string, int]
    var seenFut = newFuture[void]()
    for i in 0 ..< nodes.len:
      let dialer = nodes[i]
      var handler: TopicHandler
      closureScope:
        var peerName = $dialer.peerInfo.peerId
        handler = proc(handlerTopic: string, data: seq[byte]) {.async.} =
          seen.mgetOrPut(peerName, 0).inc()
          check handlerTopic == topic
          if not seenFut.finished() and seen.len >= numberOfNodes:
            seenFut.complete()

      dialer.subscribe(topic, handler)
    await waitSubGraph(nodes, topic)

    tryPublish await wait(
      nodes[0].publish(topic, toBytes("from node " & $nodes[0].peerInfo.peerId)),
      1.minutes,
    ), 1

    await wait(seenFut, 1.minutes)
    check:
      seen.len >= numberOfNodes
    for k, v in seen.pairs:
      check:
        v >= 1

    for node in nodes:
      check:
        topic in node.gossipsub

  asyncTest "GossipSub with multiple peers (sparse)":
    const numberOfNodes = 10
    let nodes =
      generateNodes(numberOfNodes, gossip = true, triggerSelf = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesSparse(nodes)

    var seen: Table[string, int]
    var seenFut = newFuture[void]()

    for i in 0 ..< nodes.len:
      let dialer = nodes[i]
      var handler: TopicHandler
      capture dialer, i:
        var peerName = $dialer.peerInfo.peerId
        handler = proc(handlerTopic: string, data: seq[byte]) {.async.} =
          try:
            if peerName notin seen:
              seen[peerName] = 0
            seen[peerName].inc
          except KeyError:
            raiseAssert "seen checked before"
          check handlerTopic == topic
          if not seenFut.finished() and seen.len >= numberOfNodes:
            seenFut.complete()

      dialer.subscribe(topic, handler)

    await waitSubGraph(nodes, topic)
    tryPublish await wait(
      nodes[0].publish(topic, toBytes("from node " & $nodes[0].peerInfo.peerId)),
      1.minutes,
    ), 1

    await wait(seenFut, 60.seconds)
    check:
      seen.len >= numberOfNodes
    for k, v in seen.pairs:
      check:
        v >= 1

    for node in nodes:
      check:
        topic in node.gossipsub
        node.fanout.len == 0
        node.mesh[topic].len > 0

  asyncTest "GossipSub with multiple peers - control deliver (sparse)":
    const numberOfNodes = 10

    let nodes =
      generateNodes(numberOfNodes, gossip = true, triggerSelf = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesSparse(nodes)

    var seen: Table[string, int]
    var seenFut = newFuture[void]()
    for i in 0 ..< nodes.len:
      let dialer = nodes[i]
      dialer.parameters.dHigh = 2
      dialer.parameters.dLow = 1
      dialer.parameters.d = 1
      dialer.parameters.dOut = 1
      var handler: TopicHandler
      closureScope:
        var peerName = $dialer.peerInfo.peerId
        handler = proc(handlerTopic: string, data: seq[byte]) {.async.} =
          seen.mgetOrPut(peerName, 0).inc()
          info "seen up", count = seen.len
          check handlerTopic == topic
          if not seenFut.finished() and seen.len >= numberOfNodes:
            seenFut.complete()

      dialer.subscribe(topic, handler)
      waitSubscribe(nodes[0], dialer, topic)

    # we want to test ping pong deliveries via control Iwant/Ihave, so we publish just in a tap
    let publishedTo =
      nodes[0].publish(topic, toBytes("from node " & $nodes[0].peerInfo.peerId)).await
    check:
      publishedTo != 0
      publishedTo != numberOfNodes

    await wait(seenFut, 5.minutes)
    check:
      seen.len >= numberOfNodes
    for k, v in seen.pairs:
      check:
        v >= 1

  asyncTest "GossipSub directPeers: always forward messages":
    let nodes = generateNodes(3, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)

    await nodes[0].addDirectPeer(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )
    await nodes[1].addDirectPeer(
      nodes[0].switch.peerInfo.peerId, nodes[0].switch.peerInfo.addrs
    )
    await nodes[1].addDirectPeer(
      nodes[2].switch.peerInfo.peerId, nodes[2].switch.peerInfo.addrs
    )
    await nodes[2].addDirectPeer(
      nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
    )

    var handlerFut = newFuture[void]()
    proc handler(handlerTopic: string, data: seq[byte]) {.async.} =
      check handlerTopic == topic
      handlerFut.complete()

    proc noop(handlerTopic: string, data: seq[byte]) {.async.} =
      check handlerTopic == topic

    nodes[0].subscribe(topic, noop)
    nodes[1].subscribe(topic, noop)
    nodes[2].subscribe(topic, handler)

    tryPublish await nodes[0].publish(topic, toBytes("hellow")), 1

    await handlerFut.wait(2.seconds)

    # peer shouldn't be in our mesh
    check topic notin nodes[0].mesh
    check topic notin nodes[1].mesh
    check topic notin nodes[2].mesh

  asyncTest "GossipSub directPeers: send message to unsubscribed direct peer":
    # Given 2 nodes
    const numberOfNodes = 2
    let
      nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()
      node0 = nodes[0]
      node1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # With message observers
    var
      messageReceived0 = newFuture[bool]()
      messageReceived1 = newFuture[bool]()

    proc observer0(peer: PubSubPeer, msgs: var RPCMsg) =
      for message in msgs.messages:
        if message.topic == topic:
          messageReceived0.complete(true)

    proc observer1(peer: PubSubPeer, msgs: var RPCMsg) =
      for message in msgs.messages:
        if message.topic == topic:
          messageReceived1.complete(true)

    node0.addObserver(PubSubObserver(onRecv: observer0))
    node1.addObserver(PubSubObserver(onRecv: observer1))

    # Connect them as direct peers
    await allFuturesRaising(
      node0.addDirectPeer(node1.peerInfo.peerId, node1.peerInfo.addrs),
      node1.addDirectPeer(node0.peerInfo.peerId, node0.peerInfo.addrs),
    )

    # When node 0 sends a message
    let publishResult = await node0.publish(topic, "Hello!".toBytes())
    check publishResult == 0

    # None should receive the message as they are not subscribed to the topic
    # Wait some time before asserting that messages is not received
    await sleepAsync(300.milliseconds)
    check:
      messageReceived0.finished() == false
      messageReceived1.finished() == false

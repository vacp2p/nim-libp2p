# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[sequtils, enumerate]
import stew/byteutils
import sugar
import chronicles
import ../utils
import ../../../libp2p/protocols/pubsub/[gossipsub, mcache, peertable, timedcache]
import ../../../libp2p/protocols/pubsub/rpc/[message]
import ../../helpers, ../../utils/[futures]

const MsgIdSuccess = "msg id gen success"

proc setupTest(): Future[
    tuple[
      gossip0: GossipSub, gossip1: GossipSub, receivedMessages: ref HashSet[seq[byte]]
    ]
] {.async.} =
  let nodes = generateNodes(2, gossip = true, verifySignature = false)
  discard await allFinished(nodes[0].switch.start(), nodes[1].switch.start())

  await nodes[1].switch.connect(
    nodes[0].switch.peerInfo.peerId, nodes[0].switch.peerInfo.addrs
  )

  var receivedMessages = new(HashSet[seq[byte]])

  proc handlerA(topic: string, data: seq[byte]) {.async.} =
    receivedMessages[].incl(data)

  proc handlerB(topic: string, data: seq[byte]) {.async.} =
    discard

  nodes[0].subscribe("foobar", handlerA)
  nodes[1].subscribe("foobar", handlerB)
  await waitSubGraph(nodes, "foobar")

  var gossip0: GossipSub = GossipSub(nodes[0])
  var gossip1: GossipSub = GossipSub(nodes[1])

  return (gossip0, gossip1, receivedMessages)

proc teardownTest(gossip0: GossipSub, gossip1: GossipSub) {.async.} =
  await allFuturesThrowing(gossip0.switch.stop(), gossip1.switch.stop())

proc createMessages(
    gossip0: GossipSub, gossip1: GossipSub, size1: int, size2: int
): tuple[iwantMessageIds: seq[MessageId], sentMessages: HashSet[seq[byte]]] =
  var iwantMessageIds = newSeq[MessageId]()
  var sentMessages = initHashSet[seq[byte]]()

  for i, size in enumerate([size1, size2]):
    let data = newSeqWith(size, i.byte)
    sentMessages.incl(data)

    let msg = Message.init(gossip1.peerInfo.peerId, data, "foobar", some(uint64(i + 1)))
    let iwantMessageId = gossip1.msgIdProvider(msg).expect(MsgIdSuccess)
    iwantMessageIds.add(iwantMessageId)
    gossip1.mcache.put(iwantMessageId, msg)

    let peer = gossip1.peers[(gossip0.peerInfo.peerId)]
    peer.sentIHaves[^1].incl(iwantMessageId)

  return (iwantMessageIds, sentMessages)

suite "GossipSub Integration - Message Handling":
  teardown:
    checkTrackers()

  asyncTest "Split IWANT replies when individual messages are below maxSize but combined exceed maxSize":
    # This test checks if two messages, each below the maxSize, are correctly split when their combined size exceeds maxSize.
    # Expected: Both messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()

    let messageSize = gossip1.maxMessageSize div 2 + 1
    let (iwantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, messageSize, messageSize)

    gossip1.broadcast(
      gossip1.mesh["foobar"],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: "foobar", messageIDs: iwantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    checkUntilTimeout:
      receivedMessages[].len == 2
    # check:
    #   receivedMessages[] == sentMessages


    await teardownTest(gossip0, gossip1)

  # asyncTest "Discard IWANT replies when both messages individually exceed maxSize":
  #   # This test checks if two messages, each exceeding the maxSize, are discarded and not sent.
  #   # Expected: No messages should be received.
  #   let (gossip0, gossip1, receivedMessages) = await setupTest()

  #   let messageSize = gossip1.maxMessageSize + 10
  #   let (bigIWantMessageIds, sentMessages) =
  #     createMessages(gossip0, gossip1, messageSize, messageSize)

  #   gossip1.broadcast(
  #     gossip1.mesh["foobar"],
  #     RPCMsg(
  #       control: some(
  #         ControlMessage(
  #           ihave: @[ControlIHave(topicID: "foobar", messageIDs: bigIWantMessageIds)]
  #         )
  #       )
  #     ),
  #     isHighPriority = false,
  #   )

  #   await sleepAsync(300.milliseconds)
  #   checkUntilTimeout:
  #     receivedMessages[].len == 0

  #   await teardownTest(gossip0, gossip1)

  # asyncTest "Process IWANT replies when both messages are below maxSize":
  #   # This test checks if two messages, both below the maxSize, are correctly processed and sent.
  #   # Expected: Both messages should be received.
  #   let (gossip0, gossip1, receivedMessages) = await setupTest()
  #   let size1 = gossip1.maxMessageSize div 2
  #   let size2 = gossip1.maxMessageSize div 3
  #   let (bigIWantMessageIds, sentMessages) =
  #     createMessages(gossip0, gossip1, size1, size2)

  #   gossip1.broadcast(
  #     gossip1.mesh["foobar"],
  #     RPCMsg(
  #       control: some(
  #         ControlMessage(
  #           ihave: @[ControlIHave(topicID: "foobar", messageIDs: bigIWantMessageIds)]
  #         )
  #       )
  #     ),
  #     isHighPriority = false,
  #   )

  #   checkUntilTimeout:
  #     receivedMessages[] == sentMessages
  #   check receivedMessages[].len == 2

  #   await teardownTest(gossip0, gossip1)

  # asyncTest "Split IWANT replies when one message is below maxSize and the other exceeds maxSize":
  #   # This test checks if, when given two messages where one is below maxSize and the other exceeds it, only the smaller message is processed and sent.
  #   # Expected: Only the smaller message should be received.
  #   let (gossip0, gossip1, receivedMessages) = await setupTest()
  #   let maxSize = gossip1.maxMessageSize
  #   let size1 = maxSize div 2
  #   let size2 = maxSize + 10
  #   let (bigIWantMessageIds, sentMessages) =
  #     createMessages(gossip0, gossip1, size1, size2)

  #   gossip1.broadcast(
  #     gossip1.mesh["foobar"],
  #     RPCMsg(
  #       control: some(
  #         ControlMessage(
  #           ihave: @[ControlIHave(topicID: "foobar", messageIDs: bigIWantMessageIds)]
  #         )
  #       )
  #     ),
  #     isHighPriority = false,
  #   )

  #   var smallestSet: HashSet[seq[byte]]
  #   let seqs = toSeq(sentMessages)
  #   if seqs[0] < seqs[1]:
  #     smallestSet.incl(seqs[0])
  #   else:
  #     smallestSet.incl(seqs[1])

  #   checkUntilTimeout:
  #     receivedMessages[] == smallestSet
  #   check receivedMessages[].len == 1

  #   await teardownTest(gossip0, gossip1)

  # asyncTest "messages are not sent back to source or forwarding peer":
  #   let
  #     numberOfNodes = 3
  #     topic = "foobar"
  #     nodes = generateNodes(numberOfNodes, gossip = true).toGossipSub()

  #   startNodesAndDeferStop(nodes)

  #   let (handlerFut0, handler0) = createCompleteHandler()
  #   let (handlerFut1, handler1) = createCompleteHandler()
  #   let (handlerFut2, handler2) = createCompleteHandler()

  #   # Nodes are connected in a ring
  #   await connectNodes(nodes[0], nodes[1])
  #   await connectNodes(nodes[1], nodes[2])
  #   await connectNodes(nodes[2], nodes[0])

  #   # And subscribed to the same topic
  #   subscribeAllNodes(nodes, topic, @[handler0, handler1, handler2])

  #   checkUntilTimeout:
  #     nodes.allIt(it.mesh.getOrDefault(topic).len == numberOfNodes - 1)

  #   # When node 0 sends a message
  #   check (await nodes[0].publish(topic, "Hello!".toBytes())) == 2
  #   await waitForHeartbeat()

  #   # Nodes 1 and 2 should receive the message, but node 0 shouldn't receive it back
  #   let results =
  #     await waitForStates(@[handlerFut0, handlerFut1, handlerFut2], HEARTBEAT_TIMEOUT)
  #   check:
  #     results[0].isPending()
  #     results[1].isCompleted()
  #     results[2].isCompleted()

  # asyncTest "GossipSub validation should succeed":
  #   var handlerFut = newFuture[bool]()
  #   proc handler(topic: string, data: seq[byte]) {.async.} =
  #     check topic == "foobar"
  #     handlerFut.complete(true)

  #   let nodes = generateNodes(2, gossip = true)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodesStar(nodes)

  #   nodes[0].subscribe("foobar", handler)
  #   nodes[1].subscribe("foobar", handler)

  #   var subs: seq[Future[void]]
  #   subs &= waitSub(nodes[1], nodes[0], "foobar")
  #   subs &= waitSub(nodes[0], nodes[1], "foobar")

  #   await allFuturesThrowing(subs)

  #   var validatorFut = newFuture[bool]()
  #   proc validator(
  #       topic: string, message: Message
  #   ): Future[ValidationResult] {.async.} =
  #     check topic == "foobar"
  #     validatorFut.complete(true)
  #     result = ValidationResult.Accept

  #   nodes[1].addValidator("foobar", validator)
  #   tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

  #   check (await validatorFut) and (await handlerFut)

  # asyncTest "GossipSub validation should fail (reject)":
  #   proc handler(topic: string, data: seq[byte]) {.async.} =
  #     check false # if we get here, it should fail

  #   let nodes = generateNodes(2, gossip = true)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodesStar(nodes)

  #   nodes[0].subscribe("foobar", handler)
  #   nodes[1].subscribe("foobar", handler)

  #   await waitSubGraph(nodes, "foobar")

  #   let gossip1 = GossipSub(nodes[0])
  #   let gossip2 = GossipSub(nodes[1])

  #   check:
  #     gossip1.mesh["foobar"].len == 1 and "foobar" notin gossip1.fanout
  #     gossip2.mesh["foobar"].len == 1 and "foobar" notin gossip2.fanout

  #   var validatorFut = newFuture[bool]()
  #   proc validator(
  #       topic: string, message: Message
  #   ): Future[ValidationResult] {.async.} =
  #     result = ValidationResult.Reject
  #     validatorFut.complete(true)

  #   nodes[1].addValidator("foobar", validator)
  #   tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

  #   check (await validatorFut) == true

  # asyncTest "GossipSub validation should fail (ignore)":
  #   proc handler(topic: string, data: seq[byte]) {.async.} =
  #     check false # if we get here, it should fail

  #   let nodes = generateNodes(2, gossip = true)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodesStar(nodes)

  #   nodes[0].subscribe("foobar", handler)
  #   nodes[1].subscribe("foobar", handler)

  #   await waitSubGraph(nodes, "foobar")

  #   let gossip1 = GossipSub(nodes[0])
  #   let gossip2 = GossipSub(nodes[1])

  #   check:
  #     gossip1.mesh["foobar"].len == 1 and "foobar" notin gossip1.fanout
  #     gossip2.mesh["foobar"].len == 1 and "foobar" notin gossip2.fanout

  #   var validatorFut = newFuture[bool]()
  #   proc validator(
  #       topic: string, message: Message
  #   ): Future[ValidationResult] {.async.} =
  #     result = ValidationResult.Ignore
  #     validatorFut.complete(true)

  #   nodes[1].addValidator("foobar", validator)
  #   tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

  #   check (await validatorFut) == true

  # asyncTest "GossipSub validation one fails and one succeeds":
  #   var handlerFut = newFuture[bool]()
  #   proc handler(topic: string, data: seq[byte]) {.async.} =
  #     check topic == "foo"
  #     handlerFut.complete(true)

  #   let nodes = generateNodes(2, gossip = true)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodesStar(nodes)

  #   nodes[1].subscribe("foo", handler)
  #   nodes[1].subscribe("bar", handler)

  #   var passed, failed: Future[bool] = newFuture[bool]()
  #   proc validator(
  #       topic: string, message: Message
  #   ): Future[ValidationResult] {.async.} =
  #     result =
  #       if topic == "foo":
  #         passed.complete(true)
  #         ValidationResult.Accept
  #       else:
  #         failed.complete(true)
  #         ValidationResult.Reject

  #   nodes[1].addValidator("foo", "bar", validator)
  #   tryPublish await nodes[0].publish("foo", "Hello!".toBytes()), 1
  #   tryPublish await nodes[0].publish("bar", "Hello!".toBytes()), 1

  #   check ((await passed) and (await failed) and (await handlerFut))

  #   let gossip1 = GossipSub(nodes[0])
  #   let gossip2 = GossipSub(nodes[1])

  #   check:
  #     "foo" notin gossip1.mesh and gossip1.fanout["foo"].len == 1
  #     "foo" notin gossip2.mesh and "foo" notin gossip2.fanout
  #     "bar" notin gossip1.mesh and gossip1.fanout["bar"].len == 1
  #     "bar" notin gossip2.mesh and "bar" notin gossip2.fanout

  # asyncTest "GossipSub's observers should run after message is sent, received and validated":
  #   var
  #     recvCounter = 0
  #     sendCounter = 0
  #     validatedCounter = 0

  #   proc onRecv(peer: PubSubPeer, msgs: var RPCMsg) =
  #     inc recvCounter

  #   proc onSend(peer: PubSubPeer, msgs: var RPCMsg) =
  #     inc sendCounter

  #   proc onValidated(peer: PubSubPeer, msg: Message, msgId: MessageId) =
  #     inc validatedCounter

  #   let obs0 = PubSubObserver(onSend: onSend)
  #   let obs1 = PubSubObserver(onRecv: onRecv, onValidated: onValidated)

  #   let nodes = generateNodes(2, gossip = true)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodesStar(nodes)

  #   nodes[0].addObserver(obs0)
  #   nodes[1].addObserver(obs1)
  #   nodes[1].subscribe("foo", voidTopicHandler)
  #   nodes[1].subscribe("bar", voidTopicHandler)

  #   proc validator(
  #       topic: string, message: Message
  #   ): Future[ValidationResult] {.async.} =
  #     result = if topic == "foo": ValidationResult.Accept else: ValidationResult.Reject

  #   nodes[1].addValidator("foo", "bar", validator)

  #   # Send message that will be accepted by the receiver's validator
  #   tryPublish await nodes[0].publish("foo", "Hello!".toBytes()), 1

  #   check:
  #     recvCounter == 1
  #     validatedCounter == 1
  #     sendCounter == 1

  #   # Send message that will be rejected by the receiver's validator
  #   tryPublish await nodes[0].publish("bar", "Hello!".toBytes()), 1

  #   checkUntilTimeout:
  #     recvCounter == 2
  #     validatedCounter == 1
  #     sendCounter == 2

  # asyncTest "GossipSub send over mesh A -> B":
  #   var passed: Future[bool] = newFuture[bool]()
  #   proc handler(topic: string, data: seq[byte]) {.async.} =
  #     check topic == "foobar"
  #     passed.complete(true)

  #   let nodes = generateNodes(2, gossip = true)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodesStar(nodes)

  #   nodes[0].subscribe("foobar", handler)
  #   nodes[1].subscribe("foobar", handler)
  #   await waitSub(nodes[0], nodes[1], "foobar")

  #   tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

  #   check await passed

  #   var gossip1: GossipSub = GossipSub(nodes[0])
  #   var gossip2: GossipSub = GossipSub(nodes[1])

  #   check:
  #     "foobar" in gossip1.gossipsub
  #     "foobar" in gossip2.gossipsub
  #     gossip1.mesh.hasPeerId("foobar", gossip2.peerInfo.peerId)
  #     not gossip1.fanout.hasPeerId("foobar", gossip2.peerInfo.peerId)
  #     gossip2.mesh.hasPeerId("foobar", gossip1.peerInfo.peerId)
  #     not gossip2.fanout.hasPeerId("foobar", gossip1.peerInfo.peerId)

  # asyncTest "GossipSub should not send to source & peers who already seen":
  #   # 3 nodes: A, B, C
  #   # A publishes, C relays, B is having a long validation
  #   # so B should not send to anyone

  #   let nodes = generateNodes(3, gossip = true)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodesStar(nodes)

  #   var cRelayed: Future[void] = newFuture[void]()
  #   var bFinished: Future[void] = newFuture[void]()
  #   var
  #     aReceived = 0
  #     cReceived = 0
  #   proc handlerA(topic: string, data: seq[byte]) {.async.} =
  #     inc aReceived
  #     check aReceived < 2

  #   proc handlerB(topic: string, data: seq[byte]) {.async.} =
  #     discard

  #   proc handlerC(topic: string, data: seq[byte]) {.async.} =
  #     inc cReceived
  #     check cReceived < 2
  #     cRelayed.complete()

  #   nodes[0].subscribe("foobar", handlerA)
  #   nodes[1].subscribe("foobar", handlerB)
  #   nodes[2].subscribe("foobar", handlerC)
  #   await waitSubGraph(nodes, "foobar")

  #   var gossip1: GossipSub = GossipSub(nodes[0])
  #   var gossip2: GossipSub = GossipSub(nodes[1])
  #   var gossip3: GossipSub = GossipSub(nodes[2])

  #   proc slowValidator(
  #       topic: string, message: Message
  #   ): Future[ValidationResult] {.async.} =
  #     try:
  #       await cRelayed
  #       # Empty A & C caches to detect duplicates
  #       gossip1.seen = TimedCache[SaltedId].init()
  #       gossip3.seen = TimedCache[SaltedId].init()
  #       let msgId = toSeq(gossip2.validationSeen.keys)[0]
  #       checkUntilTimeout(
  #         try:
  #           gossip2.validationSeen[msgId].len > 0
  #         except KeyError:
  #           false
  #       )
  #       result = ValidationResult.Accept
  #       bFinished.complete()
  #     except CatchableError:
  #       raiseAssert "err on slowValidator"

  #   nodes[1].addValidator("foobar", slowValidator)

  #   checkUntilTimeout:
  #     gossip1.mesh.getOrDefault("foobar").len == 2
  #     gossip2.mesh.getOrDefault("foobar").len == 2
  #     gossip3.mesh.getOrDefault("foobar").len == 2
  #   tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 2

  #   await bFinished

  # asyncTest "GossipSub send over floodPublish A -> B":
  #   var passed: Future[bool] = newFuture[bool]()
  #   proc handler(topic: string, data: seq[byte]) {.async.} =
  #     check topic == "foobar"
  #     passed.complete(true)

  #   let nodes = generateNodes(2, gossip = true)

  #   startNodesAndDeferStop(nodes)

  #   var gossip1: GossipSub = GossipSub(nodes[0])
  #   gossip1.parameters.floodPublish = true
  #   var gossip2: GossipSub = GossipSub(nodes[1])
  #   gossip2.parameters.floodPublish = true

  #   await connectNodesStar(nodes)

  #   # nodes[0].subscribe("foobar", handler)
  #   nodes[1].subscribe("foobar", handler)
  #   await waitSub(nodes[0], nodes[1], "foobar")

  #   tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

  #   check await passed.wait(10.seconds)

  #   check:
  #     "foobar" in gossip1.gossipsub
  #     "foobar" notin gossip2.gossipsub
  #     not gossip1.mesh.hasPeerId("foobar", gossip2.peerInfo.peerId)

  # asyncTest "GossipSub floodPublish limit":
  #   let
  #     nodes = setupNodes(20)
  #     gossip1 = GossipSub(nodes[0])

  #   gossip1.parameters.floodPublish = true
  #   gossip1.parameters.heartbeatInterval = milliseconds(700)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodes(nodes[1 ..^ 1], nodes[0])
  #   await baseTestProcedure(nodes, gossip1, gossip1.parameters.dLow, 17)

  # asyncTest "GossipSub floodPublish limit with bandwidthEstimatebps = 0":
  #   let
  #     nodes = setupNodes(20)
  #     gossip1 = GossipSub(nodes[0])

  #   gossip1.parameters.floodPublish = true
  #   gossip1.parameters.heartbeatInterval = milliseconds(700)
  #   gossip1.parameters.bandwidthEstimatebps = 0

  #   startNodesAndDeferStop(nodes)
  #   await connectNodes(nodes[1 ..^ 1], nodes[0])
  #   await baseTestProcedure(nodes, gossip1, nodes.len - 1, nodes.len - 1)

  # asyncTest "GossipSub with multiple peers":
  #   var runs = 10

  #   let nodes = generateNodes(runs, gossip = true, triggerSelf = true)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodesStar(nodes)

  #   var seen: Table[string, int]
  #   var seenFut = newFuture[void]()
  #   for i in 0 ..< nodes.len:
  #     let dialer = nodes[i]
  #     var handler: TopicHandler
  #     closureScope:
  #       var peerName = $dialer.peerInfo.peerId
  #       handler = proc(topic: string, data: seq[byte]) {.async.} =
  #         seen.mgetOrPut(peerName, 0).inc()
  #         check topic == "foobar"
  #         if not seenFut.finished() and seen.len >= runs:
  #           seenFut.complete()

  #     dialer.subscribe("foobar", handler)
  #   await waitSubGraph(nodes, "foobar")

  #   tryPublish await wait(
  #     nodes[0].publish("foobar", toBytes("from node " & $nodes[0].peerInfo.peerId)),
  #     1.minutes,
  #   ), 1

  #   await wait(seenFut, 1.minutes)
  #   check:
  #     seen.len >= runs
  #   for k, v in seen.pairs:
  #     check:
  #       v >= 1

  #   for node in nodes:
  #     var gossip = GossipSub(node)

  #     check:
  #       "foobar" in gossip.gossipsub

  # asyncTest "GossipSub with multiple peers (sparse)":
  #   var runs = 10

  #   let nodes = generateNodes(runs, gossip = true, triggerSelf = true)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodesSparse(nodes)

  #   var seen: Table[string, int]
  #   var seenFut = newFuture[void]()

  #   for i in 0 ..< nodes.len:
  #     let dialer = nodes[i]
  #     var handler: TopicHandler
  #     capture dialer, i:
  #       var peerName = $dialer.peerInfo.peerId
  #       handler = proc(topic: string, data: seq[byte]) {.async.} =
  #         try:
  #           if peerName notin seen:
  #             seen[peerName] = 0
  #           seen[peerName].inc
  #         except KeyError:
  #           raiseAssert "seen checked before"
  #         check topic == "foobar"
  #         if not seenFut.finished() and seen.len >= runs:
  #           seenFut.complete()

  #     dialer.subscribe("foobar", handler)

  #   await waitSubGraph(nodes, "foobar")
  #   tryPublish await wait(
  #     nodes[0].publish("foobar", toBytes("from node " & $nodes[0].peerInfo.peerId)),
  #     1.minutes,
  #   ), 1

  #   await wait(seenFut, 60.seconds)
  #   check:
  #     seen.len >= runs
  #   for k, v in seen.pairs:
  #     check:
  #       v >= 1

  #   for node in nodes:
  #     var gossip = GossipSub(node)
  #     check:
  #       "foobar" in gossip.gossipsub
  #       gossip.fanout.len == 0
  #       gossip.mesh["foobar"].len > 0

  # asyncTest "GossipSub with multiple peers - control deliver (sparse)":
  #   var runs = 10

  #   let nodes = generateNodes(runs, gossip = true, triggerSelf = true)

  #   startNodesAndDeferStop(nodes)
  #   await connectNodesSparse(nodes)

  #   var seen: Table[string, int]
  #   var seenFut = newFuture[void]()
  #   for i in 0 ..< nodes.len:
  #     let dialer = nodes[i]
  #     let dgossip = GossipSub(dialer)
  #     dgossip.parameters.dHigh = 2
  #     dgossip.parameters.dLow = 1
  #     dgossip.parameters.d = 1
  #     dgossip.parameters.dOut = 1
  #     var handler: TopicHandler
  #     closureScope:
  #       var peerName = $dialer.peerInfo.peerId
  #       handler = proc(topic: string, data: seq[byte]) {.async.} =
  #         seen.mgetOrPut(peerName, 0).inc()
  #         info "seen up", count = seen.len
  #         check topic == "foobar"
  #         if not seenFut.finished() and seen.len >= runs:
  #           seenFut.complete()

  #     dialer.subscribe("foobar", handler)
  #     await waitSub(nodes[0], dialer, "foobar")

  #   # we want to test ping pong deliveries via control Iwant/Ihave, so we publish just in a tap
  #   let publishedTo = nodes[0].publish(
  #     "foobar", toBytes("from node " & $nodes[0].peerInfo.peerId)
  #   ).await
  #   check:
  #     publishedTo != 0
  #     publishedTo != runs

  #   await wait(seenFut, 5.minutes)
  #   check:
  #     seen.len >= runs
  #   for k, v in seen.pairs:
  #     check:
  #       v >= 1

  # asyncTest "GossipSub directPeers: always forward messages":
  #   let nodes = generateNodes(3, gossip = true)

  #   startNodesAndDeferStop(nodes)

  #   await GossipSub(nodes[0]).addDirectPeer(
  #     nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
  #   )
  #   await GossipSub(nodes[1]).addDirectPeer(
  #     nodes[0].switch.peerInfo.peerId, nodes[0].switch.peerInfo.addrs
  #   )
  #   await GossipSub(nodes[1]).addDirectPeer(
  #     nodes[2].switch.peerInfo.peerId, nodes[2].switch.peerInfo.addrs
  #   )
  #   await GossipSub(nodes[2]).addDirectPeer(
  #     nodes[1].switch.peerInfo.peerId, nodes[1].switch.peerInfo.addrs
  #   )

  #   var handlerFut = newFuture[void]()
  #   proc handler(topic: string, data: seq[byte]) {.async.} =
  #     check topic == "foobar"
  #     handlerFut.complete()

  #   proc noop(topic: string, data: seq[byte]) {.async.} =
  #     check topic == "foobar"

  #   nodes[0].subscribe("foobar", noop)
  #   nodes[1].subscribe("foobar", noop)
  #   nodes[2].subscribe("foobar", handler)

  #   tryPublish await nodes[0].publish("foobar", toBytes("hellow")), 1

  #   await handlerFut.wait(2.seconds)

  #   # peer shouldn't be in our mesh
  #   check "foobar" notin GossipSub(nodes[0]).mesh
  #   check "foobar" notin GossipSub(nodes[1]).mesh
  #   check "foobar" notin GossipSub(nodes[2]).mesh

  # asyncTest "GossipSub directPeers: send message to unsubscribed direct peer":
  #   # Given 2 nodes
  #   let
  #     numberOfNodes = 2
  #     nodes = generateNodes(numberOfNodes, gossip = true)
  #     node0 = nodes[0]
  #     node1 = nodes[1]
  #     g0 = GossipSub(node0)
  #     g1 = GossipSub(node1)

  #   startNodesAndDeferStop(nodes)

  #   # With message observers
  #   var
  #     messageReceived0 = newFuture[bool]()
  #     messageReceived1 = newFuture[bool]()

  #   proc observer0(peer: PubSubPeer, msgs: var RPCMsg) =
  #     for message in msgs.messages:
  #       if message.topic == "foobar":
  #         messageReceived0.complete(true)

  #   proc observer1(peer: PubSubPeer, msgs: var RPCMsg) =
  #     for message in msgs.messages:
  #       if message.topic == "foobar":
  #         messageReceived1.complete(true)

  #   node0.addObserver(PubSubObserver(onRecv: observer0))
  #   node1.addObserver(PubSubObserver(onRecv: observer1))

  #   # Connect them as direct peers
  #   await g0.addDirectPeer(node1.peerInfo.peerId, node1.peerInfo.addrs)
  #   await g1.addDirectPeer(node0.peerInfo.peerId, node0.peerInfo.addrs)

  #   # When node 0 sends a message
  #   let message = "Hello!".toBytes()
  #   let publishResult = await node0.publish("foobar", message)

  #   # None should receive the message as they are not subscribed to the topic
  #   let results = await waitForStates(@[messageReceived0, messageReceived1])
  #   check:
  #     publishResult == 0
  #     results[0].isPending()
  #     results[1].isPending()

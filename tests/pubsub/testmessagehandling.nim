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
import utils
import ../../libp2p/protocols/pubsub/[gossipsub, mcache]
import ../../libp2p/protocols/pubsub/rpc/[message]
import ../../libp2p/muxers/muxer
import ../../libp2p/protocols/pubsub/rpc/protobuf
import ../helpers, ../utils/[futures]

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

suite "GossipSub Message Handling":
  teardown:
    checkTrackers()

  asyncTest "Drop messages of topics without subscription":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    proc handler(peer: PubSubPeer, data: seq[byte]) {.async: (raises: []).} =
      check false

    let topic = "foobar"
    var conns = newSeq[Connection]()
    for i in 0 ..< 30:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      peer.handler = handler

    # generate messages
    var seqno = 0'u64
    for i in 0 .. 5:
      let conn = TestBufferStream.new(noop)
      conns &= conn
      let peerId = randomPeerId()
      conn.peerId = peerId
      let peer = gossipSub.getPubSubPeer(peerId)
      inc seqno
      let msg = Message.init(peerId, ("bar" & $i).toBytes(), topic, some(seqno))
      await gossipSub.rpcHandler(peer, encodeRpcMsg(RPCMsg(messages: @[msg]), false))

    check gossipSub.mcache.msgs.len == 0

    await allFuturesThrowing(conns.mapIt(it.close()))
    await gossipSub.switch.stop()

  asyncTest "subscription limits":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    gossipSub.topicsHigh = 10

    var tooManyTopics: seq[string]
    for i in 0 .. gossipSub.topicsHigh + 10:
      tooManyTopics &= "topic" & $i
    let lotOfSubs = RPCMsg.withSubs(tooManyTopics, true)

    let conn = TestBufferStream.new(noop)
    let peerId = randomPeerId()
    conn.peerId = peerId
    let peer = gossipSub.getPubSubPeer(peerId)

    await gossipSub.rpcHandler(peer, encodeRpcMsg(lotOfSubs, false))

    check:
      gossipSub.gossipsub.len == gossipSub.topicsHigh
      peer.behaviourPenalty > 0.0

    await conn.close()
    await gossipSub.switch.stop()

  asyncTest "invalid message bytes":
    let gossipSub = TestGossipSub.init(newStandardSwitch())

    let peerId = randomPeerId()
    let peer = gossipSub.getPubSubPeer(peerId)

    expect(CatchableError):
      await gossipSub.rpcHandler(peer, @[byte 1, 2, 3])

    await gossipSub.switch.stop()

  asyncTest "e2e - Split IWANT replies when individual messages are below maxSize but combined exceed maxSize":
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
      receivedMessages[] == sentMessages
    check receivedMessages[].len == 2

    await teardownTest(gossip0, gossip1)

  asyncTest "e2e - Discard IWANT replies when both messages individually exceed maxSize":
    # This test checks if two messages, each exceeding the maxSize, are discarded and not sent.
    # Expected: No messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()

    let messageSize = gossip1.maxMessageSize + 10
    let (bigIWantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, messageSize, messageSize)

    gossip1.broadcast(
      gossip1.mesh["foobar"],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: "foobar", messageIDs: bigIWantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    await sleepAsync(300.milliseconds)
    checkUntilTimeout:
      receivedMessages[].len == 0

    await teardownTest(gossip0, gossip1)

  asyncTest "e2e - Process IWANT replies when both messages are below maxSize":
    # This test checks if two messages, both below the maxSize, are correctly processed and sent.
    # Expected: Both messages should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()
    let size1 = gossip1.maxMessageSize div 2
    let size2 = gossip1.maxMessageSize div 3
    let (bigIWantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, size1, size2)

    gossip1.broadcast(
      gossip1.mesh["foobar"],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: "foobar", messageIDs: bigIWantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    checkUntilTimeout:
      receivedMessages[] == sentMessages
    check receivedMessages[].len == 2

    await teardownTest(gossip0, gossip1)

  asyncTest "e2e - Split IWANT replies when one message is below maxSize and the other exceeds maxSize":
    # This test checks if, when given two messages where one is below maxSize and the other exceeds it, only the smaller message is processed and sent.
    # Expected: Only the smaller message should be received.
    let (gossip0, gossip1, receivedMessages) = await setupTest()
    let maxSize = gossip1.maxMessageSize
    let size1 = maxSize div 2
    let size2 = maxSize + 10
    let (bigIWantMessageIds, sentMessages) =
      createMessages(gossip0, gossip1, size1, size2)

    gossip1.broadcast(
      gossip1.mesh["foobar"],
      RPCMsg(
        control: some(
          ControlMessage(
            ihave: @[ControlIHave(topicID: "foobar", messageIDs: bigIWantMessageIds)]
          )
        )
      ),
      isHighPriority = false,
    )

    var smallestSet: HashSet[seq[byte]]
    let seqs = toSeq(sentMessages)
    if seqs[0] < seqs[1]:
      smallestSet.incl(seqs[0])
    else:
      smallestSet.incl(seqs[1])

    checkUntilTimeout:
      receivedMessages[] == smallestSet
    check receivedMessages[].len == 1

    await teardownTest(gossip0, gossip1)

asyncTest "messages are not sent back to source or forwarding peer":
  let
    numberOfNodes = 3
    topic = "foobar"
    nodes = generateNodes(numberOfNodes, gossip = true)

  startNodesAndDeferStop(nodes)

  let (handlerFut0, handler0) = createCompleteHandler()
  let (handlerFut1, handler1) = createCompleteHandler()
  let (handlerFut2, handler2) = createCompleteHandler()

  # Nodes are connected in a ring
  await connectNodes(nodes[0], nodes[1])
  await connectNodes(nodes[1], nodes[2])
  await connectNodes(nodes[2], nodes[0])

  # And subscribed to the same topic
  subscribeAllNodes(nodes, topic, @[handler0, handler1, handler2])
  await waitForPeersInTable(
    nodes, topic, newSeqWith(numberOfNodes, 2), PeerTableType.Mesh
  )

  # When node 0 sends a message
  check (await nodes[0].publish(topic, "Hello!".toBytes())) == 2
  await waitForHeartbeat()

  # Nodes 1 and 2 should receive the message, but node 0 shouldn't receive it back
  let results =
    await waitForStates(@[handlerFut0, handlerFut1, handlerFut2], HEARTBEAT_TIMEOUT)
  check:
    results[0].isPending()
    results[1].isCompleted()
    results[2].isCompleted()

# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import std/[options, deques, sequtils, enumerate, algorithm]
import stew/byteutils
import ../../libp2p/builders
import ../../libp2p/errors
import ../../libp2p/crypto/crypto
import ../../libp2p/stream/bufferstream
import ../../libp2p/protocols/pubsub/[pubsub, gossipsub, mcache, mcache, peertable]
import ../../libp2p/protocols/pubsub/rpc/[message, messages]
import ../../libp2p/switch
import ../../libp2p/muxers/muxer
import ../../libp2p/protocols/pubsub/rpc/protobuf
import utils

import ../helpers

const MsgIdSuccess = "msg id gen success"

suite "GossipSub internal":
  teardown:
    checkTrackers()

  asyncTest "topic params":
    let params = TopicParams.init()
    params.validateParameters().tryGet()

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

  asyncTest "Disconnect bad peers":
    let gossipSub = TestGossipSub.init(newStandardSwitch())
    gossipSub.parameters.disconnectBadPeers = true
    gossipSub.parameters.appSpecificWeight = 1.0
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
      peer.sendConn = conn
      peer.handler = handler
      peer.appScore = gossipSub.parameters.graylistThreshold - 1
      gossipSub.gossipsub.mgetOrPut(topic, initHashSet[PubSubPeer]()).incl(peer)
      gossipSub.switch.connManager.storeMuxer(Muxer(connection: conn))

    gossipSub.updateScores()

    await sleepAsync(100.millis)

    check:
      # test our disconnect mechanics
      gossipSub.gossipsub.peers(topic) == 0
      # also ensure we cleanup properly the peersInIP table
      gossipSub.peersInIP.len == 0

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

      let msg =
        Message.init(gossip1.peerInfo.peerId, data, "foobar", some(uint64(i + 1)))
      let iwantMessageId = gossip1.msgIdProvider(msg).expect(MsgIdSuccess)
      iwantMessageIds.add(iwantMessageId)
      gossip1.mcache.put(iwantMessageId, msg)

      let peer = gossip1.peers[(gossip0.peerInfo.peerId)]
      peer.sentIHaves[^1].incl(iwantMessageId)

    return (iwantMessageIds, sentMessages)

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

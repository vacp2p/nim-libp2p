# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, algorithm, stew/byteutils, sequtils
import
  ../../../../libp2p/protocols/pubsub/[
    gossipsub,
    gossipsub/extensions,
    gossipsub/extension_preamble,
    pubsubpeer,
    rpc/message,
  ]
import ../../../tools/[lifecycle, unittest]
import ../extensions/my_partial_message
import ../utils

# this file tests integration of gossipsub with extensions. 
# tests here do not need to be very comprehensive, because it is enough 
# to test integration with extension and gossipsub. more detailed tests
# should be added to test files of respective extensions.

suite "GossipSub Component - Extensions":
  teardown:
    checkTrackers()

  asyncTest "Test Extension":
    var negotiatedPeers: seq[PeerId]
    proc onNegotiated(peer: PeerId) {.gcsafe, raises: [].} =
      negotiatedPeers.add(peer)

    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          testExtensionConfig =
            Opt.some(TestExtensionConfig(onNegotiated: onNegotiated)),
        )
        .toGossipSub()

    startAndDeferStop(nodes)

    await connect(nodes[0], nodes[1])

    let nodesPeerIdSorted = pluckPeerId(nodes).sorted()
    untilTimeout:
      pre:
        let negotiatedPeersSorted = negotiatedPeers.sorted()
      check:
        negotiatedPeersSorted == nodesPeerIdSorted

  asyncTest "Extensions control is sent before subscriptions on stream open":
    # If node has pre-existing subsciptions on a dial,
    # then it sends the subscriptions control message before extensions control message on a newly opened stream,
    # which violates the protocol contract.
    const topic = "logos-extensions-ordering"
    var
      dialerFirstOutgoing = Opt.none(RPCMsg)
      receiverFirstOutgoing = Opt.none(RPCMsg)

    proc onNegotiated(_: PeerId) {.gcsafe, raises: [].} =
      discard

    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          testExtensionConfig =
            Opt.some(TestExtensionConfig(onNegotiated: onNegotiated)),
        )
        .toGossipSub()

    # Observe the first outgoing message from each node to the other.
    let receiverPeerId = nodes[0].peerInfo.peerId
    let dialerPeerId = nodes[1].peerInfo.peerId

    nodes[1].addObserver(
      PubSubObserver(
        onSend: proc(peer: PubSubPeer, msg: var RPCMsg) {.gcsafe, raises: [].} =
          if peer.peerId == receiverPeerId and dialerFirstOutgoing.isNone:
            dialerFirstOutgoing = Opt.some(msg)
      )
    )
    nodes[0].addObserver(
      PubSubObserver(
        onSend: proc(peer: PubSubPeer, msg: var RPCMsg) {.gcsafe, raises: [].} =
          if peer.peerId == dialerPeerId and receiverFirstOutgoing.isNone:
            receiverFirstOutgoing = Opt.some(msg)
      )
    )

    startAndDeferStop(nodes)

    # Subscribe before connect
    nodes.subscribeAllNodes(topic, voidTopicHandler)

    await connect(nodes[1], nodes[0])

    checkUntilTimeout:
      dialerFirstOutgoing.isSome() and receiverFirstOutgoing.isSome()

    # First message must be extensions control, no subscriptions.
    check:
      # Dialer side
      dialerFirstOutgoing.get().control.isSome()
      dialerFirstOutgoing.get().control.get().extensions.isSome()
      dialerFirstOutgoing.get().subscriptions.len == 0
      # Receiver side
      receiverFirstOutgoing.get().control.isSome()
      receiverFirstOutgoing.get().control.get().extensions.isSome()
      receiverFirstOutgoing.get().subscriptions.len == 0

  asyncTest "Extensions re-negotiated after disconnect/reconnect with correct ordering":
    const topic = "foobar"

    var negotiatedPeers: seq[PeerId]
    proc onNegotiated(peer: PeerId) {.gcsafe, raises: [].} =
      negotiatedPeers.add(peer)

    # Track all outgoing messages per (sender, receiver) pair in send order.
    var outgoingMsgs: Table[string, seq[RPCMsg]]

    proc key(sender, receiver: PeerId): string =
      $sender & "->" & $receiver

    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          testExtensionConfig =
            Opt.some(TestExtensionConfig(onNegotiated: onNegotiated)),
        )
        .toGossipSub()

    let
      peerId0 = nodes[0].peerInfo.peerId
      peerId1 = nodes[1].peerInfo.peerId
      k0to1 = key(peerId0, peerId1)
      k1to0 = key(peerId1, peerId0)

    # Observe all outgoing messages from both nodes.
    nodes[0].addObserver(
      PubSubObserver(
        onSend: proc(peer: PubSubPeer, msg: var RPCMsg) {.gcsafe, raises: [].} =
          let k = key(peerId0, peer.peerId)
          outgoingMsgs.mgetOrPut(k, @[]).add(msg)
      )
    )
    nodes[1].addObserver(
      PubSubObserver(
        onSend: proc(peer: PubSubPeer, msg: var RPCMsg) {.gcsafe, raises: [].} =
          let k = key(peerId1, peer.peerId)
          outgoingMsgs.mgetOrPut(k, @[]).add(msg)
      )
    )

    startAndDeferStop(nodes)

    # Subscribe before connecting — the scenario that triggers the original bug.
    nodes.subscribeAllNodes(topic, voidTopicHandler)

    # First connection
    await connect(nodes[1], nodes[0])

    # Wait for both sides to have sent at least extensions.
    checkUntilTimeout:
      outgoingMsgs.getOrDefault(k0to1).len >= 1
      outgoingMsgs.getOrDefault(k1to0).len >= 1

    # Both sides: first message is extensions control, not subscriptions.
    check:
      outgoingMsgs[k0to1][0].control.isSome()
      outgoingMsgs[k0to1][0].control.get().extensions.isSome()
      outgoingMsgs[k0to1][0].subscriptions.len == 0
      outgoingMsgs[k1to0][0].control.isSome()
      outgoingMsgs[k1to0][0].control.get().extensions.isSome()
      outgoingMsgs[k1to0][0].subscriptions.len == 0

    # Both peers should have negotiated.
    checkUntilTimeout:
      negotiatedPeers.len == 2

    # Disconnect from both sides to ensure clean state
    outgoingMsgs.clear()
    await nodes[1].switch.disconnect(peerId0)
    await nodes[0].switch.disconnect(peerId1)

    checkUntilTimeout:
      not nodes[1].switch.isConnected(peerId0) and
        not nodes[0].switch.isConnected(peerId1)

    # Reconnect: node 1 dials node 0
    await connect(nodes[1], nodes[0])

    checkUntilTimeout:
      outgoingMsgs.getOrDefault(k1to0).len >= 1
      outgoingMsgs.getOrDefault(k0to1).len >= 1

    # Both sides: first message is extensions control, not subscriptions.
    check:
      outgoingMsgs[k1to0][0].control.isSome()
      outgoingMsgs[k1to0][0].control.get().extensions.isSome()
      outgoingMsgs[k1to0][0].subscriptions.len == 0
      outgoingMsgs[k0to1][0].control.isSome()
      outgoingMsgs[k0to1][0].control.get().extensions.isSome()
      outgoingMsgs[k0to1][0].subscriptions.len == 0

    # Extensions must have been re-negotiated (new callbacks fired).
    checkUntilTimeout:
      negotiatedPeers.len == 4

  asyncTest "No extensions control sent when node has no extensions configured":
    const topic = "foobar"
    var outgoingMsgs: seq[RPCMsg]

    let nodes = generateNodes(2, gossip = true).toGossipSub()

    let remotePeerId = nodes[0].peerInfo.peerId
    nodes[1].addObserver(
      PubSubObserver(
        onSend: proc(peer: PubSubPeer, msg: var RPCMsg) {.gcsafe, raises: [].} =
          if peer.peerId == remotePeerId:
            outgoingMsgs.add(msg)
      )
    )

    startAndDeferStop(nodes)
    nodes.subscribeAllNodes(topic, voidTopicHandler)
    await connect(nodes[1], nodes[0])

    # Wait for subscriptions to propagate.
    waitSubscribeStar(nodes, topic)

    # None of the sent messages should contain extensions control.
    check:
      outgoingMsgs.len >= 1

    for msg in outgoingMsgs:
      if msg.control.isSome():
        check msg.control.get().extensions.isNone()

  asyncTest "Extensions control sent exactly once per peer per connection":
    # Guard: hasControlBeenSent returns true after first send => no duplicates.
    const topic = "foobar"

    proc onNegotiated(_: PeerId) {.gcsafe, raises: [].} =
      discard

    var extControlCount: int = 0

    let nodes = generateNodes(
        2,
        gossip = true,
        testExtensionConfig = Opt.some(TestExtensionConfig(onNegotiated: onNegotiated)),
      )
      .toGossipSub()

    let remotePeerId = nodes[0].peerInfo.peerId
    nodes[1].addObserver(
      PubSubObserver(
        onSend: proc(peer: PubSubPeer, msg: var RPCMsg) {.gcsafe, raises: [].} =
          if peer.peerId == remotePeerId and msg.control.isSome():
            if msg.control.get().extensions.isSome():
              extControlCount.inc
      )
    )

    startAndDeferStop(nodes)
    nodes.subscribeAllNodes(topic, voidTopicHandler)
    await connect(nodes[1], nodes[0])

    waitSubscribeStar(nodes, topic)

    # Wait a few heartbeats to ensure no late duplicates arrive.
    await sleepAsync(500.milliseconds)

    check extControlCount == 1

  asyncTest "Partial Message Extension":
    const topic = "logos-partial"
    const groupId = "group-id-1".toBytes

    proc validateRPC(
        rpc: PartialMessageExtensionRPC
    ): Result[void, string] {.gcsafe, raises: [].} =
      checkLen(rpc.partsMetadata)
      return ok()

    var incomingRPC: Table[PeerId, seq[PartialMessageExtensionRPC]]
    proc onIncomingRPC(
        peer: PeerId, rpc: PartialMessageExtensionRPC
    ) {.gcsafe, raises: [].} =
      # peer - who sent RPC (received from)
      incomingRPC.mgetOrPut(peer, newSeq[PartialMessageExtensionRPC]()).add(rpc)

      # note: ideally this is where applications will publish partial messages on requests.
      # but for the sake of tests it is much more easier and intuitive to follow when 
      # rpc are added to table, and testing is done in procedural, like in test below.

    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          partialMessageExtensionConfig = Opt.some(
            PartialMessageExtensionConfig(
              unionPartsMetadata: my_partial_message.unionPartsMetadata,
              validateRPC: validateRPC,
              onIncomingRPC: onIncomingRPC,
              heartbeatsTillEviction: 100,
            )
          ),
        )
        .toGossipSub()

    startAndDeferStop(nodes)

    await connect(nodes[0], nodes[1])

    # subscribe all nodes requesting partial messages and wait for subscribe
    for node in nodes:
      node.subscribe(topic, voidTopicHandler, requestsPartial = true)
    checkUntilTimeout:
      nodes.allIt(it.gossipsub.getOrDefault(topic).len == 1)

    # node 1 seeks for parts 1, 2, 3
    let node1Req = MyPartialMessage(groupID: groupId, want: @[1, 2, 3])
    await nodes[1].publishPartial(topic, node1Req)

    # wait for node 0 to receive request
    checkUntilTimeout:
      # to get messages received by node 0, we need to 
      # get messages that are sent by node 1.
      incomingRPC.getOrDefault(nodes[1].peerInfo.peerId, @[]).len == 1

    # assert that node 0 received exactly what node 1 sent
    check:
      incomingRPC[nodes[1].peerInfo.peerId][0] ==
        PartialMessageExtensionRPC(
          topicID: topic,
          groupID: groupId,
          partsMetadata: MyPartsMetadata.want(node1Req.want),
        )

    # then node 0 publishes data
    let pmData = MyPartialMessage(
      groupID: groupId,
      data: {1: "one".toBytes, 2: "two".toBytes, 3: "three".toBytes}.toTable,
    )
    await nodes[0].publishPartial(topic, pmData)

    # wait for node 1 to receive partial message
    checkUntilTimeout:
      incomingRPC.getOrDefault(nodes[0].peerInfo.peerId, @[]).len == 1

    # assert that node 1 received exactly what node 0 sent
    check:
      incomingRPC[nodes[0].peerInfo.peerId][0] ==
        PartialMessageExtensionRPC(
          topicID: topic,
          groupID: groupId,
          partialMessage: "onetwothree".toBytes,
          partsMetadata: MyPartsMetadata.have(toSeq(pmData.data.keys)),
        )

  asyncTest "PingPong Extension":
    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          pingpongExtensionConfig = Opt.some(PingPongExtensionConfig()),
        )
        .toGossipSub()

    startAndDeferStop(nodes)

    await connect(nodes[0], nodes[1])

    let pingBytes = @[1'u8, 2, 3, 4, 5]
    var receivedPong: seq[byte]

    # observe pong received by nodes[0] after it sends a ping
    nodes[0].addObserver(
      PubSubObserver(
        onRecv: proc(peer: PubSubPeer, msg: var RPCMsg) {.gcsafe, raises: [].} =
          msg.pingpongExtension.withValue(ppe):
            if ppe.pong.len > 0:
              receivedPong = ppe.pong
      )
    )

    # send ping from nodes[0] to nodes[1]
    nodes[0].send(
      nodes[0].peers[nodes[1].peerInfo.peerId],
      RPCMsg.withPing(pingBytes),
      MessagePriority.High,
    )

    # nodes[1] should echo the ping back as a pong
    checkUntilTimeout:
      receivedPong == pingBytes

  asyncTest "Preamble Extension":
    const topic = "preamble-topic"

    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          preambleExtensionConfig = Opt.some(PreambleExtensionConfig()),
          sendIDontWantOnPublish = true,
        )
        .toGossipSub()

    # Capture IMReceiving messages received by nodes[1] (sent by nodes[0] after processing the preamble)
    var receivedImReceiving: seq[IMReceiving]
    nodes[1].addObserver(
      PubSubObserver(
        onRecv: proc(peer: PubSubPeer, msgs: var RPCMsg) {.gcsafe, raises: [].} =
          msgs.preambleExtension.withValue(pe):
            for ir in pe.imreceiving:
              receivedImReceiving.add(ir)
      )
    )

    startAndDeferStop(nodes)

    await connect(nodes[0], nodes[1])

    subscribeAllNodes(nodes, topic, voidTopicHandler)
    waitSubscribeStar(nodes, topic)

    # publishing large message should publish preamble (nodes[0] will receive preamble as well).
    let msgLength = preambleMessageSizeThreshold + 4 # some large message length
    discard await nodes[1].publish(topic, newSeq[byte](msgLength))

    # nodes[1] should receive IMReceiving right after it broadcasted preamble.
    checkUntilTimeout:
      receivedImReceiving.len == 1
      receivedImReceiving[0].messageLength == msgLength.uint32

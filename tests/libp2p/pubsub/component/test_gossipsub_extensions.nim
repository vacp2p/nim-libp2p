# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, algorithm, stew/byteutils, sequtils
import
  ../../../../libp2p/protocols/pubsub/[gossipsub, gossipsub/extensions, rpc/message]
import ../../../tools/[lifecycle, unittest]
import ../extensions/my_partial_message
import ../utils

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
          testExtensionConfig = some(TestExtensionConfig(onNegotiated: onNegotiated)),
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

      # note: ideally this is were applications will publish partial messages on requests.
      # but for the sake of tests it is much more easier and intuitive to follow when 
      # rpc are added to table, and testing is done in procedural, like in test below.

    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          partialMessageExtensionConfig = some(
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
    let mpWant = MyPartialMessage(groupID: groupId, want: @[1, 2, 3])
    await nodes[1].publishPartial(topic, mpWant)

    # wait for node 0 to receive request
    checkUntilTimeout:
      # note: nodes[1] is used here because node 0 receives RPC from node 1.
      # in other words, to get messages received by node 0, we need to 
      # get messages that are sent by node 1.
      incomingRPC.getOrDefault(nodes[1].peerInfo.peerId, @[]).len == 1

    # assert that node 0 received exactly what node 1 sent
    check:
      incomingRPC[nodes[1].peerInfo.peerId][0] ==
        PartialMessageExtensionRPC(
          topicID: topic,
          groupID: groupId,
          partsMetadata: MyPartsMetadata.want(@[1, 2, 3]),
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
          partsMetadata: MyPartsMetadata.have(@[1, 2, 3]),
        )

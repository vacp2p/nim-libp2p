# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, sequtils, stew/byteutils, utils
import ../../../libp2p/[peerid]
import
  ../../../libp2p/protocols/pubsub/
    [gossipsub, gossipsub/preamblestore, mcache, rpc/message]
import ../../tools/[unittest]

suite "GossipSub 1.4":
  teardown:
    checkTrackers()

  proc generateMessageIds(count: int): seq[MessageId] =
    return (0 ..< count).mapIt(("msg_id_" & $it & $Moment.now()).toBytes())

  asyncTest "emit IMReceiving while handling preamble control msg":
    # Given GossipSub node with 1 peer
    let
      topic = "foobar"
      totalPeers = 2

    let
      nodes = generateNodes(totalPeers, gossip = true).toGossipSub()
      n0 = nodes[0]
      n1 = nodes[1]

    startNodesAndDeferStop(nodes)

    # And the nodes are connected
    await connectNodesStar(nodes)

    # And both subscribe to the topic
    subscribeAllNodes(nodes, topic, voidTopicHandler)
    await waitForHeartbeat()

    let msgId = generateMessageIds(1)[0]
    let preambles =
      @[
        ControlPreamble(
          topicID: topic,
          messageID: msgId,
          messageLength: preambleMessageSizeThreshold + 1,
        )
      ]

    let p1 = n0.getOrCreatePeer(n1.peerInfo.peerId, @[GossipSubCodec_14])
    check:
      p1.preambleBudget == PreamblePeerBudget

    n0.handlePreamble(p1, preambles)

    check:
      p1.preambleBudget == PreamblePeerBudget - 1 # Preamble budget should decrease
      p1.heIsSendings.hasKey(msgId)
      n0.ongoingReceives.hasKey(msgId)

    # TODO: check that some peer receives ControlIMReceiving
    await waitForHeartbeat()

    let p2 = n1.getOrCreatePeer(n0.peerInfo.peerId, @[GossipSubCodec_14])
    check:
      p2.heIsReceivings.hasKey(msgId)

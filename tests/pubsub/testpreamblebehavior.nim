import unittest2

{.used.}

import chronos
import ../../libp2p/[peerid, protocols/pubsub/rpc/messages]
import ../utils/async_tests
import sequtils
import ../helpers
import stew/byteutils
import utils
import ../../libp2p/protocols/pubsub/gossipsub/preamblestore
import ../../libp2p/protocols/pubsub/[gossipsub, mcache]
import ../../libp2p/protocols/pubsub/rpc/[message]

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

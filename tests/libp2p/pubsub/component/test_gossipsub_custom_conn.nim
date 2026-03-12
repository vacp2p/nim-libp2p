# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, stew/byteutils
import ../../../../libp2p/stream/connection
import
  ../../../../libp2p/protocols/pubsub/[gossipsub, peertable, pubsubpeer, rpc/messages]
import ../../../tools/[lifecycle, topology, unittest]
import ../utils

type DummyConnection* = ref object of Connection
  data: seq[byte]

method write*(
    self: DummyConnection, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  self.data.add(msg)

suite "GossipSub Component - Custom Connection Support":
  const topic = "foobar"

  teardown:
    checkTrackers()

  asyncTest "publish with useCustomConn triggers custom connection and peer selection":
    let nodes = generateNodes(2, gossip = true).toGossipSub()

    var 
      dummyConn = DummyConnection()
      peerSelectionCalled = false

    nodes[0].customConnCallbacks = some(
      CustomConnectionCallbacks(
        customConnCreationCB: proc(
            destAddr: Option[MultiAddress], destPeerId: PeerId, codec: string
        ): Connection =
          return dummyConn,
        customPeerSelectionCB: proc(
            allPeers: HashSet[PubSubPeer],
            directPeers: HashSet[PubSubPeer],
            meshPeers: HashSet[PubSubPeer],
            fanoutPeers: HashSet[PubSubPeer],
        ): HashSet[PubSubPeer] =
          peerSelectionCalled = true
          return allPeers,
      )
    )

    startAndDeferStop(nodes)
    await connectStar(nodes)

    nodes[1].subscribe(topic, voidTopicHandler)
    waitSubscribe(nodes[0], nodes[1], topic)

    tryPublish await nodes[0].publish(
      topic, "hello".toBytes(), publishParams = some(PublishParams(useCustomConn: true))
    ), 1

    check:
      peerSelectionCalled
      dummyConn.data.len > 0

  asyncTest "publish with useCustomConn triggers assertion if custom callbacks not set":
    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startAndDeferStop(nodes)
    await connectStar(nodes)

    nodes[1].subscribe(topic, voidTopicHandler)
    waitSubscribe(nodes[0], nodes[1], topic)

    expect AssertionDefect:
      discard await nodes[0].publish(
        topic,
        "hello".toBytes(),
        publishParams = some(PublishParams(useCustomConn: true)),
      )

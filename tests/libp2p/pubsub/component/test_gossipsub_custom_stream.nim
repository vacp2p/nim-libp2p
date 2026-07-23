# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, stew/byteutils
import ../../../../libp2p/stream/connection
import
  ../../../../libp2p/protocols/pubsub/[gossipsub, peertable, pubsubpeer, rpc/messages]
import ../../../tools/[lifecycle, topology, unittest3]
import ../utils

type DummyStream* = ref object of Connection
  data: seq[byte]

method write*(
    self: DummyStream, msg: sink seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
  self.data.add(msg)

suite "GossipSub Component - Custom Stream Support":
  const topic = "foobar"

  # teardown: disabled as it can be flaky with concurrent tests
  #   checkTrackers()

  asyncTest "publish with useCustomStream triggers custom stream and peer selection":
    let nodes = generateNodes(2, gossip = true).toGossipSub()

    var
      dummyStream = DummyStream()
      peerSelectionCalled = false

    nodes[0].customStreamCallbacks = Opt.some(
      CustomStreamCallbacks(
        customStreamCreationCB: proc(
            destAddr: Opt[MultiAddress], destPeerId: PeerId, codec: string
        ): Stream =
          return dummyStream,
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
      topic,
      "hello".toBytes(),
      publishParams = Opt.some(PublishParams(useCustomStream: true)),
    ), 1

    check:
      peerSelectionCalled
      dummyStream.data.len > 0

  asyncTest "publish with useCustomStream triggers assertion if custom callbacks not set":
    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startAndDeferStop(nodes)
    await connectStar(nodes)

    nodes[1].subscribe(topic, voidTopicHandler)
    waitSubscribe(nodes[0], nodes[1], topic)

    expect AssertionDefect:
      discard await nodes[0].publish(
        topic,
        "hello".toBytes(),
        publishParams = Opt.some(PublishParams(useCustomStream: true)),
      )

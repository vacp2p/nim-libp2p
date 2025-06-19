# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos
import stew/byteutils
import ../utils
import ../../../libp2p/protocols/pubsub/[gossipsub, peertable, pubsubpeer]
import ../../../libp2p/protocols/pubsub/rpc/[messages]
import ../../../libp2p/stream/connection
import ../../helpers

type DummyConnection* = ref object of Connection

method write*(
    self: DummyConnection, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true), public.} =
  let fut = newFuture[void]()
  fut.complete()
  return fut

proc new*(T: typedesc[DummyConnection]): DummyConnection =
  let instance = T()
  instance

suite "GossipSub Integration - Custom Connection Support":
  teardown:
    checkTrackers()

  asyncTest "publish with useCustomConn triggers custom connection and peer selection":
    let
      topic = "test"
      handler = proc(topic: string, data: seq[byte]) {.async.} =
        discard
      nodes = generateNodes(2, gossip = true)

    var
      customConnCreated = false
      peerSelectionCalled = false

    GossipSub(nodes[0]).customConnCallbacks = some(
      CustomConnectionCallbacks(
        customConnCreationCB: proc(
            destAddr: Option[MultiAddress], destPeerId: PeerId, codec: string
        ): Connection =
          customConnCreated = true
          return DummyConnection.new(),
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

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, handler)
    await waitSub(nodes[0], nodes[1], topic)

    tryPublish await nodes[0].publish(topic, "hello".toBytes(), useCustomConn = true), 1

    check:
      peerSelectionCalled
      customConnCreated

  asyncTest "publish with useCustomConn triggers assertion if custom callbacks not set":
    let
      topic = "test"
      handler = proc(topic: string, data: seq[byte]) {.async.} =
        discard
      nodes = generateNodes(2, gossip = true)

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    nodes[1].subscribe(topic, handler)
    await waitSub(nodes[0], nodes[1], topic)

    var raised = false
    try:
      discard await nodes[0].publish(topic, "hello".toBytes(), useCustomConn = true)
    except Defect:
      raised = true

    check raised

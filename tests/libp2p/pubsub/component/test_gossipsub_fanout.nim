# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, stew/byteutils
import ../../../../libp2p/protocols/pubsub/[gossipsub, peertable, rpc/messages]
import ../../../tools/[unittest]
import ../utils

suite "GossipSub Component - Fanout Management":
  teardown:
    checkTrackers()

  asyncTest "GossipSub send over fanout A -> B":
    let nodes = generateNodes(2, gossip = true).toGossipSub()

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    let (passed, handler) = createCompleteHandler()
    nodes[1].subscribe("foobar", handler)
    waitSubscribe(nodes[0], nodes[1], "foobar")

    var observed = 0
    let
      obs1 = PubSubObserver(
        onRecv: proc(peer: PubSubPeer, msgs: var RPCMsg) =
          inc observed
      )
      obs2 = PubSubObserver(
        onSend: proc(peer: PubSubPeer, msgs: var RPCMsg) =
          inc observed
      )

    nodes[1].addObserver(obs1)
    nodes[0].addObserver(obs2)

    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    discard await passed.wait(2.seconds)

    check:
      "foobar" in nodes[0].gossipsub
      nodes[0].fanout.hasPeerId("foobar", nodes[1].peerInfo.peerId)
      not nodes[0].mesh.hasPeerId("foobar", nodes[1].peerInfo.peerId)

    check observed == 2

  asyncTest "GossipSub send over fanout A -> B for subscribed topic":
    let nodes =
      generateNodes(2, gossip = true, unsubscribeBackoff = 10.minutes).toGossipSub()

    nodes[1].parameters.d = 0
    nodes[1].parameters.dHigh = 0
    nodes[1].parameters.dLow = 0

    startNodesAndDeferStop(nodes)
    await connectNodesStar(nodes)

    let (passed, handler) = createCompleteHandler()
    nodes[1].subscribe("foobar", handler)
    waitSubscribe(nodes[0], nodes[1], "foobar")

    checkUntilTimeout:
      nodes[0].mesh.getOrDefault("foobar").len == 0
      nodes[1].mesh.getOrDefault("foobar").len == 0
      (
        nodes[0].gossipsub.getOrDefault("foobar").len == 1 or
        nodes[0].fanout.getOrDefault("foobar").len == 1
      )

    tryPublish await nodes[0].publish("foobar", "Hello!".toBytes()), 1

    discard await passed.wait(2.seconds)
    check:
      nodes[0].mesh.getOrDefault("foobar").len == 0
      nodes[0].fanout.getOrDefault("foobar").len == 1

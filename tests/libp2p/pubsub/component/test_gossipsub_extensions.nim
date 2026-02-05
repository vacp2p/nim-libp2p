# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, algorithm
import
  ../../../../libp2p/protocols/pubsub/[gossipsub, gossipsub/extensions, rpc/message]
import ../../../tools/[lifecycle, unittest]
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

    startNodesAndDeferStop(nodes)

    await connect(nodes[0], nodes[1])

    let nodesPeerIdSorted = pluckPeerId(nodes).sorted()
    untilTimeout:
      pre:
        let negotiatedPeersSorted = negotiatedPeers.sorted()
      check:
        negotiatedPeersSorted == nodesPeerIdSorted

  asyncTest "Partial Message Extension":
    proc validateRPC(
        rpc: PartialMessageExtensionRPC
    ): Result[void, string] {.gcsafe, raises: [].} =
      ok()

    proc onIncomingRPC(
        peer: PeerId, rpc: PartialMessageExtensionRPC
    ) {.gcsafe, raises: [].} =
      discard

    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          partialMessageExtensionConfig = some(
            PartialMessageExtensionConfig(
              validateRPC: validateRPC, onIncomingRPC: onIncomingRPC
            )
          ),
        )
        .toGossipSub()

    startNodesAndDeferStop(nodes)

    await connect(nodes[0], nodes[1])

    # TODO

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, algorithm
import
  ../../../../libp2p/protocols/pubsub/
    [gossipsub, gossipsub/extensions, gossipsub/partial_message, rpc/message]
import ../../../tools/unittest
import ../utils

suite "GossipSub Component - Extensions":
  teardown:
    checkTrackers()

  asyncTest "Test Extension":
    var (negotiatedPeers, onNegotiated) = createCollectPeerCallback()
    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          testExtensionConfig = some(TestExtensionConfig(onNegotiated: onNegotiated)),
        )
        .toGossipSub()

    startNodesAndDeferStop(nodes)

    await connectNodes(nodes[0], nodes[1])

    let nodesPeerIdSorted = pluckPeerId(nodes).sorted()
    untilTimeout:
      pre:
        let negotiatedPeersSorted = negotiatedPeers[].sorted()
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

    proc mergeMetadata(a, b: PartsMetadata): PartsMetadata {.gcsafe, raises: [].} =
      return a

    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          partialMessageExtensionConfig = some(
            PartialMessageExtensionConfig(
              validateRPC: validateRPC,
              onIncomingRPC: onIncomingRPC,
              mergeMetadata: mergeMetadata,
            )
          ),
        )
        .toGossipSub()

    startNodesAndDeferStop(nodes)

    await connectNodes(nodes[0], nodes[1])

    # TODO

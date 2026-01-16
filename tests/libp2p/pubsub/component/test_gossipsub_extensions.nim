# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, algorithm
import
  ../../../../libp2p/protocols/pubsub/[gossipsub, gossipsub/extensions, rpc/message]
import ../../../tools/unittest
import ../utils

suite "GossipSub Extensions":
  teardown:
    checkTrackers()

  asyncTest "TestExtension":
    var
      (negotiatedPeers, onNegotiated) = createCollectPeerCallback()
      (handleRPCPeers, onHandleRPC) = createCollectPeerCallback()
    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          testExtensionConfig = some(
            TestExtensionConfig(onNegotiated: onNegotiated, onHandleRPC: onHandleRPC)
          ),
        )
        .toGossipSub()

    startNodesAndDeferStop(nodes)

    await connectNodes(nodes[0], nodes[1])

    let nodesPeerIdSorted = pluckPeerId(nodes).sorted()
    untilTimeout:
      pre:
        let negotiatedPeersSorted = negotiatedPeers[].sorted()
        let handleRPCPeersSorted = handleRPCPeers[].sorted()
      check:
        negotiatedPeersSorted == nodesPeerIdSorted
        handleRPCPeersSorted == nodesPeerIdSorted

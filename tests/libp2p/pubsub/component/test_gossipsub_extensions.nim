# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

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
      (handleRPCPeers, onHandleControlRPC) = createCollectPeerCallback()
    let
      numberOfNodes = 2
      nodes = generateNodes(
          numberOfNodes,
          gossip = true,
          testExtensionConfig = some(
            TestExtensionConfig(
              onNegotiated: onNegotiated, onHandleControlRPC: onHandleControlRPC
            )
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

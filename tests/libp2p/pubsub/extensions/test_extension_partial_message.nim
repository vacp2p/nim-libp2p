# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results
import ../../../../libp2p/peerid
import
  ../../../../libp2p/protocols/pubsub/[
    gossipsub/extension_partial_message,
    gossipsub/partial_message,
    gossipsub/extensions_types,
    rpc/messages,
  ]
import ../../../tools/[unittest]
import ../utils

suite "GossipSub Extensions :: Partial Message Extension":
  test "basic test":
    proc sendRPC(
        peerID: PeerId, rpc: PartialMessageExtensionRPC
    ) {.gcsafe, raises: [].} =
      discard

    proc publishToPeers(topic: string): seq[PeerId] {.gcsafe, raises: [].} =
      return newSeq[PeerId]()

    proc isRequestPartialByNode(topic: string): bool {.gcsafe, raises: [].} =
      return false

    proc isSupportedCb(peer: PeerId): bool {.gcsafe, raises: [].} =
      return true

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

    let cfg = PartialMessageExtensionConfig(
      sendRPC: sendRPC,
      publishToPeers: publishToPeers,
      isSupported: isSupportedCb,
      isRequestPartialByNode: isRequestPartialByNode,
      validateRPC: validateRPC,
      onIncomingRPC: onIncomingRPC,
      mergeMetadata: mergeMetadata,
    )
    let ext = PartialMessageExtension.new(cfg)

    check:
      ext.isSupported(PeerExtensions()) == false
      ext.isSupported(PeerExtensions(partialMessageExtension: true)) == true

    # TODO

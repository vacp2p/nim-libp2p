# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results
import ../../../../libp2p/peerid
import
  ../../../../libp2p/protocols/pubsub/
    [gossipsub/extension_partial_message, gossipsub/partial_message, gossipsub/extensions_types, rpc/messages]
import ../../../tools/[unittest]
import ../utils

suite "GossipSub Extensions :: Partial Message Extension":
  test "basic test":
    let sendRPC = proc(
        peerID: PeerId, rpc: PartialMessageExtensionRPC
    ) {.gcsafe, raises: [].} =
      discard
    let publishToPeers = proc(topic: string): seq[PeerId] {.gcsafe, raises: [].} =
      return newSeq[PeerId]()
    let isSupportedCb = proc(peer: PeerId): bool {.gcsafe, raises: [].} =
      return true
    let validateRPC = proc(
        rpc: PartialMessageExtensionRPC
    ): Result[void, string] {.gcsafe, raises: [].} =
      ok()
    let onIncomingRPC = proc(
        peer: PeerId, rpc: PartialMessageExtensionRPC
    ) {.gcsafe, raises: [].} =
      discard
    let mergeMetadata = proc(
        a, b: PartsMetadata
    ): PartsMetadata {.gcsafe, raises: [].} =
      return a

    let cfg = PartialMessageExtensionConfig(
      sendRPC: sendRPC,
      publishToPeers: publishToPeers,
      isSupported: isSupportedCb,
      validateRPC: validateRPC,
      onIncomingRPC: onIncomingRPC,
      mergeMetadata: mergeMetadata,
    )
    let ext = PartialMessageExtension.new(cfg)

    check:
      ext.isSupported(PeerExtensions()) == false
      ext.isSupported(PeerExtensions(partialMessageExtension: true)) == true

    # TODO

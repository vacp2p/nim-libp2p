# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import ../../../../libp2p/peerid
import ../../../../libp2p/protocols/pubsub/[gossipsub/extensions_types, rpc/messages]

type RecordingExtension* = ref object of Extension
  # basic implementation that records method calls.
  heartbeatCount*: int
  negotiatedPeers*: seq[PeerId]
  removedPeers*: seq[PeerId]
  handledRPC*: seq[RPCMsg]

method isSupported*(
    ext: RecordingExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.testExtension

method onHeartbeat*(ext: RecordingExtension) {.gcsafe, raises: [].} =
  ext.heartbeatCount.inc

method onNegotiated*(ext: RecordingExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.negotiatedPeers.add(peerId)

method onRemovePeer*(ext: RecordingExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.removedPeers.add(peerId)

method onHandleRPC*(
    ext: RecordingExtension, peerId: PeerId, rpc: RPCMsg
) {.gcsafe, raises: [].} =
  ext.handledRPC.add(rpc)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import ../../../../libp2p/peerid
import ../../../../libp2p/protocols/pubsub/[gossipsub/extensions_types, rpc/messages]

type DelegateExtension* = ref object of Extension
  heartbeatCount*: int
  negotiatedPeers*: seq[PeerId]
  removedPeers*: seq[PeerId]
  handledRPC*: seq[RPCMsg]

method isSupported*(
    ext: DelegateExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.testExtension

method onHeartbeat*(ext: DelegateExtension) {.gcsafe, raises: [].} =
  ext.heartbeatCount.inc

method onNegotiated*(ext: DelegateExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.negotiatedPeers.add(peerId)

method onRemovePeer*(ext: DelegateExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.removedPeers.add(peerId)

method onHandleRPC*(
    ext: DelegateExtension, peerId: PeerId, rpc: RPCMsg
) {.gcsafe, raises: [].} =
  ext.handledRPC.add(rpc)

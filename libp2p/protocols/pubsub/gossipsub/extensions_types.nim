# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import ../../../[peerid]
import ../rpc/messages

proc noopPeerCallback*(peer: PeerId) {.gcsafe, raises: [].} =
  discard

type
  PeerExtensions* = object # holds all capabilities that are supported with extensions.
    testExtension*: bool # is "test extension" supported? 
    partialMessageExtension*: bool # is "partial message extension" supported?

  PeerCallback* = proc(peer: PeerId) {.gcsafe, raises: [].}

  Extension* = ref object of RootObj
    #
    # base type of all extensions

method isSupported*(
    ext: Extension, pe: PeerExtensions
): bool {.base, gcsafe, raises: [].} =
  ## should return _true_ if this extension is supported by
  ## provided PeerExtensions.
  raiseAssert "isSupported: must be implemented"

method onHeartbeat*(ext: Extension) {.base, gcsafe, raises: [].} =
  ## called on every gossipsub heartbeat.
  raiseAssert "onHeartbeat: must be implemented"

method onNegotiated*(ext: Extension, peerId: PeerId) {.base, gcsafe, raises: [].} =
  # called as soon as node and peer have negotiated extensions and both support 
  # this extension.
  raiseAssert "onNegotiated: must be implemented"

method onRemovePeer*(ext: Extension, peerId: PeerId) {.base, gcsafe, raises: [].} =
  # called after peer has disconnected from node, or in general removed from gossipsub.
  # extensions should remove any data associated with this peer.
  raiseAssert "onRemovePeer: must be implemented"

method onHandleRPC*(
    ext: Extension, peerId: PeerId, rpc: RPCMsg
) {.base, gcsafe, raises: [].} =
  # called when gossipsub receives every RPC message.
  raiseAssert "onHandleRPC: must be implemented"

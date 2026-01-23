# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import ../../../[peerid]

proc noopPeerCallback*(peer: PeerId) {.gcsafe, raises: [].} =
  discard

type
  PeerExtensions* = object
    testExtension*: bool
    partialMessageExtension*: bool

  PeerCallback* = proc(peer: PeerId) {.gcsafe, raises: [].}

  Extension* = ref object of RootObj # base type of all extensions

method isSupported*(
    ext: Extension, pe: PeerExtensions
): bool {.base, gcsafe, raises: [].} =
  raiseAssert "must be implemented"

method onHeartbeat*(ext: Extension) {.base, gcsafe, raises: [].} =
  raiseAssert "must be implemented"

method onNegotiated*(ext: Extension, peerId: PeerId) {.base, gcsafe, raises: [].} =
  raiseAssert "must be implemented"

method onRemovePeer*(ext: Extension, peerId: PeerId) {.base, gcsafe, raises: [].} =
  raiseAssert "must be implemented"

method onHandleRPC*(ext: Extension, peerId: PeerId) {.base, gcsafe, raises: [].} =
  raiseAssert "must be implemented"

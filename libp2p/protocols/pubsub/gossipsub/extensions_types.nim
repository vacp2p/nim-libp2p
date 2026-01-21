# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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

method onNegotiated*(ext: Extension, peerId: PeerId) {.base, gcsafe, raises: [].} =
  raiseAssert "must be implemented"

method onHandleRPC*(ext: Extension, peerId: PeerId) {.base, gcsafe, raises: [].} =
  raiseAssert "must be implemented"

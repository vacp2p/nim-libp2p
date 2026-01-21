# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ../../../[peerid]
import ./[extensions_types]

type
  TestExtensionConfig* = object
    onNegotiated*: PeerCallback = noopPeerCallback
    onHandleRPC*: PeerCallback = noopPeerCallback

  TestExtension* = ref object of Extension
    config: TestExtensionConfig

proc new*(T: typedesc[TestExtension], config: TestExtensionConfig): Extension =
  TestExtension(config: config)

method isSupported*(
    ext: TestExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.testExtension

method onHeartbeat*(ext: TestExtension) {.gcsafe, raises: [].} =
  discard # should not do anything

method onNegotiated*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.config.onNegotiated(peerId)

method onHandleRPC*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.config.onHandleRPC(peerId)

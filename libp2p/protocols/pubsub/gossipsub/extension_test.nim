# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import ../../../[peerid]
import ./[extensions_types]

type
  TestExtensionConfig* = object
    onNegotiated*: PeerCallback = noopPeerCallback
    onHandleRPC*: PeerCallback = noopPeerCallback

  TestExtension* = ref object of Extension
    config: TestExtensionConfig

proc new*(T: typedesc[TestExtension], config: TestExtensionConfig): TestExtension =
  TestExtension(config: config)

method isSupported*(
    ext: TestExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.testExtension

method onHeartbeat*(ext: TestExtension) {.gcsafe, raises: [].} =
  discard # should not do anything

method onNegotiated*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.config.onNegotiated(peerId)

method onRemovePeer*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  discard # should not do anything

method onHandleRPC*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.config.onHandleRPC(peerId)

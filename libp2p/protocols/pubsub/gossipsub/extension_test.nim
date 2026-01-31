# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types]

type
  TestExtensionConfig* = object
    onNegotiated*: PeerCallback

  TestExtension* = ref object of Extension
    onNegotiated: PeerCallback

proc new*(T: typedesc[TestExtension], config: TestExtensionConfig): TestExtension =
  TestExtension(onNegotiated: config.onNegotiated)

method isSupported*(
    ext: TestExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.testExtension

method onHeartbeat*(ext: TestExtension) {.gcsafe, raises: [].} =
  discard # NOOP

method onNegotiated*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.onNegotiated(peerId)

method onRemovePeer*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  discard # NOOP

method onHandleRPC*(
    ext: TestExtension, peerId: PeerId, rpc: RPCMsg
) {.gcsafe, raises: [].} =
  discard # NOOP

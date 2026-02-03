# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types]

type
  OnNegotiatedProc* = proc(peer: PeerId) {.gcsafe, raises: [].}
    # called when "test extension" has negotiated with the peer.
    # default implementation is set by gossipsub.

  TestExtensionConfig* = object
    onNegotiated*: proc(peer: PeerId) {.gcsafe, raises: [].}
      # called when this extensions has negotiated with the peer.
      # default implementation is set by GossipSub.createExtensionsState.

  TestExtension* = ref object of Extension
    config: TestExtensionConfig

proc doAssert(config: TestExtensionConfig) =
  doAssert(config.onNegotiated != nil, "TestExtensionConfig.onNegotiated must be set")

proc doAssert(config: TestExtensionConfig) =
  doAssert(config.onNegotiated != nil, "config.onNegotiated must be set")

proc new*(T: typedesc[TestExtension], config: TestExtensionConfig): TestExtension =
  config.doAssert()
  TestExtension(config: config)

method isSupported*(
    ext: TestExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.testExtension

method onHeartbeat*(ext: TestExtension) {.gcsafe, raises: [].} =
  discard # NOOP

method onNegotiated*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.config.onNegotiated(peerId)

method onRemovePeer*(ext: TestExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  discard # NOOP

method onHandleRPC*(
    ext: TestExtension, peerId: PeerId, rpc: RPCMsg
) {.gcsafe, raises: [].} =
  discard # NOOP

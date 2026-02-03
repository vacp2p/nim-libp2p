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
    onNegotiated*: OnNegotiatedProc

  TestExtension* = ref object of Extension
    onNegotiated: OnNegotiatedProc

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

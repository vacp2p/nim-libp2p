# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import tables
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types]

const PingsPeerBudget* = 100
  # maximum of 6.4kb/heartbeat (6.4kb/s with default 1 second/hb)

type
  PingPongExtensionConfig* = object
    sendPong*: proc(peerID: PeerId, pong: seq[byte]) {.gcsafe, raises: [].}

  PingPongExtension* = ref object of Extension
    config: PingPongExtensionConfig
    usedBudget: Table[PeerId, int]

proc doAssert(config: PingPongExtensionConfig) =
  doAssert(config.sendPong != nil, "PingPongExtensionConfig.sendPong must be set")

proc new*(
    T: typedesc[PingPongExtension], config: PingPongExtensionConfig
): PingPongExtension =
  config.doAssert()
  PingPongExtension(config: config)

method isSupported*(
    ext: PingPongExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.pingpongExtension

method onHeartbeat*(ext: PingPongExtension) {.gcsafe, raises: [].} =
  ext.usedBudget.clear()

method onNegotiated*(ext: PingPongExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  discard # NOOP

method onRemovePeer*(ext: PingPongExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  discard # NOOP

method onHandleRPC*(
    ext: PingPongExtension, peerId: PeerId, rpc: RPCMsg
) {.gcsafe, raises: [].} =
  rpc.pingpongExtension.withValue(ppe):
    if ppe.ping.len > 0 and ext.usedBudget.getOrDefault(peerId) < PingsPeerBudget:
      ext.usedBudget[peerId] = ext.usedBudget.getOrDefault(peerId) + 1
      ext.config.sendPong(peerId, ppe.ping)

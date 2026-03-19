# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import tables
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types]

type
  PreambleExtensionConfig* = object
    maxPreamblePeerBudget*: int = 10
    maxHeIsReceiving*: int = 50
    broadcastPreamble*:
      proc(preamble: ControlMessage, peers: seq[PeerId]) {.gcsafe, raises: [].}

  PreambleExtension* = ref object of Extension
    config: PreambleExtensionConfig
    preambleBudgetUsed: Table[PeerId, int]

proc doAssert(config: PreambleExtensionConfig) =
  doAssert(
    config.maxPreamblePeerBudget > 0,
    "PreambleExtensionConfig.maxPreamblePeerBudget must be positive (> 0)",
  )
  doAssert(
    config.maxHeIsReceiving > 0,
    "PreambleExtensionConfig.maxHeIsReceiving must be positive (> 0)",
  )
  doAssert(
    config.broadcastPreamble != nil,
    "PreambleExtensionConfig.broadcastPreamble must be set",
  )

proc new*(
    T: typedesc[PreambleExtension], config: PreambleExtensionConfig
): PreambleExtension =
  config.doAssert()
  PreambleExtension(config: config)

method isSupported*(
    ext: PreambleExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.preambleExtension

method stop*(ext: PreambleExtension) {.gcsafe, raises: [].} =
  discard # TODO

method onHeartbeat*(ext: PreambleExtension) {.gcsafe, raises: [].} =
  ext.preambleBudgetUsed.clear()

method onNegotiated*(ext: PreambleExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  discard # TODO

method onRemovePeer*(ext: PreambleExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  discard # TODO

method onHandleRPC*(
    ext: PreambleExtension, peerId: PeerId, rpc: RPCMsg
) {.gcsafe, raises: [].} =
  # read control message read preamble and imreceiving
  # g.handlePreamble(peer, control.preamble)
  # g.handleIMReceiving(peer, control.imreceiving)
  discard # TODO

proc preambleBroadcast*(
    ext: PreambleExtension, preambleMsg: ControlMessage, peers: seq[PeerId]
) =
  if preambleMsg.preamble.len == 0: # no preambles, skip sending
    return
  ext.config.broadcastPreamble(preambleMsg, peers)

proc preambleBroadcastIfNotReceiving*(
    ext: PreambleExtension, preambleMsg: ControlMessage, peers: seq[PeerId]
) =
  # TODO filter peers
  ext.preambleBroadcast(preambleMsg, peers)

proc preambleMsgReceived*(ext: PreambleExtension, peerId: PeerId, msgId: MessageId) =
  discard
  # g.ongoingReceives.del(msgId)
  # g.ongoingIWantReceives.del(msgId)
  # var startTime: Moment
  # if peer.heIsSendings.pop(msgId, startTime):
  #   peer.bandwidthTracking.download.update(startTime, msg.data.len)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, tables, sequtils
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types, preamblestore, ../bandwidth]

const preambleMessageSizeThreshold* = 40 * 1024 # 40KiB

type
  PreambleExtensionConfig* = object
    maxPreamblePeerBudget*: int = 10
    maxHeIsReceiving*: int = 50
    broadcastPreamble*:
      proc(preamble: ControlMessage, peers: seq[PeerId]) {.gcsafe, raises: [].}

  PeerState = ref object
    heIsReceivings*: Table[MessageId, uint32]
    heIsSendings*: Table[MessageId, Moment]
    bandwidthTracking: BandwidthTracking

  PreambleExtension* = ref object of Extension
    config: PreambleExtensionConfig
    supportingPeers: seq[PeerId]
    preambleBudgetUsed: Table[PeerId, int]
    peerState: Table[PeerId, PeerState]
    ongoingReceives*: PreambleStore # list of messages we are receiving
    ongoingIWantReceives*: PreambleStore # list of iwant replies we are receiving

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

method onStop*(ext: PreambleExtension) {.gcsafe, raises: [].} =
  discard # TODO

method onHeartbeat*(ext: PreambleExtension) {.gcsafe, raises: [].} =
  ext.preambleBudgetUsed.clear()

method onNegotiated*(ext: PreambleExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  ext.supportingPeers.add(peerId)

  var peerState = PeerState.new()
  peerState.bandwidthTracking =
    BandwidthTracking(download: ExponentialMovingAverage.init())
  ext.peerState[peerId] = peerState

method onRemovePeer*(ext: PreambleExtension, peerId: PeerId) {.gcsafe, raises: [].} =
  let i = ext.supportingPeers.find(peerId)
  if i != -1:
    ext.supportingPeers.delete(i)

  ext.peerState.del(peerId)

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

  let broadcastToPeers = peers.filterIt(it in ext.supportingPeers)
  ext.config.broadcastPreamble(preambleMsg, broadcastToPeers)

proc preambleBroadcastIfNotReceiving*(
    ext: PreambleExtension, preambleMsg: ControlMessage, peers: seq[PeerId]
) =
  proc isMsgInIMReceiving(peerId: PeerId): bool =
    let peerState = ext.peerState.getOrDefault(peerId)
    if peerState.heIsReceivings.hasKey(preambleMsg.preamble[0].messageID):
      # libp2p_gossipsub_imreceiving_saved_messages.inc
      return true
    return false

  let broadcastToPeers = peers.filterIt(isMsgInIMReceiving(it))
  ext.preambleBroadcast(preambleMsg, broadcastToPeers)

proc preambleMsgReceived*(
    ext: PreambleExtension, peerId: PeerId, msgId: MessageId, msgLen: int
) =
  if msgLen < preambleMessageSizeThreshold:
    return

  ext.ongoingReceives.del(msgId)
  ext.ongoingIWantReceives.del(msgId)

  var peerState = ext.peerState[peerId]
  var startTime: Moment
  if peerState.heIsSendings.pop(msgId, startTime):
    peerState.bandwidthTracking.download.update(startTime, msgLen)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, tables, sequtils, algorithm
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types, preamblestore, ../bandwidth]

logScope:
  topics = "libp2p preamble"

const preambleMessageSizeThreshold* = 40 * 1024 # 40KiB

type
  PreambleExtensionConfig* = object
    maxPreamblePeerBudget*: int = 10
    maxHeIsReceiving*: int = 50
    broadcastPreamble*:
      proc(preamble: ControlMessage, peers: seq[PeerId]) {.gcsafe, raises: [].}
    hasSeen*: proc(mid: MessageId): bool {.gcsafe, raises: [].}
    mashAndDirectPeersForTopic*: proc(topic: string): seq[PeerId] {.gcsafe, raises: [].}

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
  doAssert(config.hasSeen != nil, "PreambleExtensionConfig.hasSeen must be set")
  doAssert(
    config.mashAndDirectPeersForTopic != nil,
    "PreambleExtensionConfig.mashAndDirectPeersForTopic must be set",
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

proc medianDownloadRate(ext: PreambleExtension, peers: seq[PeerId]): float =
  if peers.len == 0:
    return 0

  let vals = peers
    .mapIt(ext.peerState.getOrDefault(it).bandwidthTracking.download.value())
    .sorted()
  let mid = vals.len div 2
  if vals.len mod 2 == 0:
    (vals[mid - 1] + vals[mid]) / 2
  else:
    vals[mid]

proc handlePreamble*(
    ext: PreambleExtension, peerId: PeerId, preambles: seq[ControlPreamble]
) =
  let starts = Moment.now()

  for preamble in preambles:
    let peerUsedBudget = ext.preambleBudgetUsed.getOrDefault(peerId)
    if peerUsedBudget >= ext.config.maxPreamblePeerBudget:
      return
    ext.preambleBudgetUsed[peerId] = peerUsedBudget + 1

    if ext.config.hasSeen(preamble.messageID):
      continue

    let peerState = ext.peerState.getOrDefault(peerId)
    if peerState.heIsSendings.hasKey(preamble.messageID):
      continue

    if ext.ongoingReceives.hasKey(preamble.messageID):
      #TODO: add to conflicts_watch if length is different
      continue

    peerState.heIsSendings[preamble.messageID] = starts

    var toSendPeers = ext.config.mashAndDirectPeersForTopic(preamble.topicID)
    var peers = toSendPeers.filterIt(it in ext.supportingPeers)

    let bytesPerSecond = peerState.bandwidthTracking.download.value()
    let transmissionTimeMs =
      calculateReceiveTimeMs(preamble.messageLength.int64, bytesPerSecond.int64)
    let expires = starts + transmissionTimeMs.milliseconds

    # We send imreceiving only if received from mesh members
    if peerId notin peers:
      trace "preamble: ignoring out of mesh peer", peerId
      if not ext.ongoingIWantReceives.hasKey(preamble.messageID):
        ext.ongoingIWantReceives.insert(
          PreambleInfo.init(preamble, peerId, starts, expires)
        )
      continue

    ext.ongoingReceives.insert(PreambleInfo.init(preamble, peerId, starts, expires))

    # Send imreceiving only if received from faster mesh members
    if bytesPerSecond >= ext.medianDownloadRate(toSendPeers):
      ext.config.broadcastPreamble(ControlMessage.withImreceiving(preamble), peers)

method onHandleRPC*(
    ext: PreambleExtension, peerId: PeerId, rpc: RPCMsg
) {.gcsafe, raises: [].} =
  rpc.control.withValue(control):
    ext.handlePreamble(peerId, control.preamble)

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
    let msgId =
      try:
        preambleMsg.preamble[0].messageID
      except KeyError:
        return false

    let peerState = ext.peerState.getOrDefault(peerId)
    if peerState.heIsReceivings.hasKey(msgId):
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

  try:
    var peerState = ext.peerState[peerId]
    var startTime: Moment
    if peerState.heIsSendings.pop(msgId, startTime):
      peerState.bandwidthTracking.download.update(startTime, msgLen)
  except KeyError:
    discard

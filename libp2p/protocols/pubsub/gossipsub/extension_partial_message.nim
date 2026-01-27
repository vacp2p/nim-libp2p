# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import tables, strutils
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types, partial_message]

const
  minHeartbeatsTillEviction = 3
  keyDelimiter = "::"

type
  SendRPCProc =
    proc(peerID: PeerId, rpc: PartialMessageExtensionRPC) {.gcsafe, raises: [].}
  PublishToPeersProc = proc(topic: string): seq[PeerId] {.gcsafe, raises: [].}
  IsSupportedProc = proc(peer: PeerId): bool {.gcsafe, raises: [].}

  PartialMessageExtensionConfig* = object
    sendRPC*: SendRPCProc
    publishToPeers*: PublishToPeersProc
    isSupported*: IsSupportedProc
    heartbeatsTillEviction*: int

  PeerGroupState = ref object
    partsMetadata: seq[byte]

  GroupState = ref object
    peerState: Table[PeerId, PeerGroupState]
    heartbeatsTillEviction: int

  SubState = ref object
    requestsPartial: bool
    supportsSendingPartial: bool

  PeerTopicKey = string
  TopicGroupKey = string

  PartialMessageExtension* = ref object of Extension
    sendRPC: SendRPCProc
    publishToPeers: PublishToPeersProc
    isSupported: IsSupportedProc
    heartbeatsTillEviction: int
    groupState: Table[TopicGroupKey, GroupState]
    peerSubs: Table[PeerTopicKey, SubState]

proc new(
    T: typedesc[PeerTopicKey], peerId: PeerId, topic: string
): PeerTopicKey {.inline.} =
  $peerId & keyDelimiter & topic

proc hasPeer(key: PeerTopicKey, peerId: PeerId): bool =
  return ($peerId & keyDelimiter) in cast[string](key)

proc new(
    T: typedesc[TopicGroupKey], topic: string, groupID: seq[byte]
): TopicGroupKey {.inline.} =
  topic & keyDelimiter & cast[string](groupID)

proc new*(
    T: typedesc[PartialMessageExtension], config: PartialMessageExtensionConfig
): PartialMessageExtension =
  doAssert(config.sendRPC != nil, "config.sendRPC must be set")
  doAssert(config.publishToPeers != nil, "config.publishToPeers must be set")
  doAssert(config.isSupported != nil, "config.isSupported must be set")

  PartialMessageExtension(
    sendRPC: config.sendRPC,
    publishToPeers: config.publishToPeers,
    isSupported: config.isSupported,
    heartbeatsTillEviction:
      max(config.heartbeatsTillEviction, minHeartbeatsTillEviction),
  )

method isSupported*(
    ext: PartialMessageExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.partialMessageExtension

method onHeartbeat*(ext: PartialMessageExtension) {.gcsafe, raises: [].} =
  # reduce heartbeatsTillEviction and remove those that hit 0
  var toRemove: seq[TopicGroupKey] = @[]
  for key, group in ext.groupState:
    group.heartbeatsTillEviction.dec
    if group.heartbeatsTillEviction <= 0:
      toRemove.add(key)
  for key in toRemove:
    ext.groupState.del(key)

method onNegotiated*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  discard # NOOP

method onRemovePeer*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  # remove peer data from groupState
  for key, group in ext.groupState:
    group.peerState.del(peerId)

  # remove subscription options for this peer 
  var toRemove: seq[PeerTopicKey] = @[]
  for key, _ in ext.peerSubs:
    if key.hasPeer(peerId):
      toRemove.add(key)
  for key in toRemove:
    ext.groupState.del(key)

proc handleSubscribe(ext: PartialMessageExtension, peerId: PeerId, rpc: SubOpts) =
  let key = PeerTopicKey.new(peerId, rpc.topic)
  if rpc.subscribe:
    let rp = rpc.requestsPartial.valueOr:
      false
    let ssp = rpc.supportsSendingPartial.valueOr:
      false

    ext.peerSubs[key] = SubState(
      requestsPartial: rp,
      supportsSendingPartial: rp or ssp,
        # when peer requested partial, then, by spec, they must support it
    )
  else:
    ext.peerSubs.del(key)

proc handlePartial(
    ext: PartialMessageExtension, peerId: PeerId, rpc: PartialMessageExtensionRPC
) =
  discard # TODO

method onHandleRPC*(
    ext: PartialMessageExtension, peerId: PeerId, rpc: RPCMsg
) {.gcsafe, raises: [].} =
  for subRPC in rpc.subscriptions:
    ext.handleSubscribe(peerId, subRPC)

  rpc.partialMessageExtension.withValue(partialExtRPC):
    ext.handlePartial(peerId, partialExtRPC)

proc getGroupState(
    ext: PartialMessageExtension, topic: string, groupID: seq[byte]
): GroupState =
  let key = TopicGroupKey.new(topic, groupID)

  if key notin ext.groupState:
    ext.groupState[key] = GroupState()

  try:
    return ext.groupState[key]
  except KeyError:
    raiseAssert "checked with if"

proc getPeerState(gs: GroupState, peerId: PeerId): PeerGroupState =
  if peerId notin gs.peerState:
    gs.peerState[peerId] = PeerGroupState()

  try:
    return gs.peerState[peerId]
  except KeyError:
    raiseAssert "checked with if"

proc publishPartial*(
    ext: PartialMessageExtension, topic: string, pm: PartialMessage
): int {.raises: [].} =
  let groupID = pm.groupID()
  let partsMetada = pm.partsMetadata()
  let groupState = ext.getGroupState(topic, groupID)

  groupState.heartbeatsTillEviction = ext.heartbeatsTillEviction

  proc publishPartialToPeer(peer: PeerId) {.raises: [].} =
    var rpc = PartialMessageExtensionRPC(topicID: topic, groupID: groupID)
    let peerState = groupState.getPeerState(peer)
    var lastPartsMetadata = peerState.partsMetadata
    var peerRequestsPartial: bool = true
    var hasChanges: bool = false

    # if peer has requested partial messages, attempt to fulfill any 
    # parts that peer is missing.
    if peerRequestsPartial:
      let data = pm.partialMessage(lastPartsMetadata)
      if data.len > 0:
        hasChanges = true
        rpc.partialMessage = data
        # state.newParts(data)  ???

    # if partsMetada was changed, rpc sets new metadata 
    if lastPartsMetadata != partsMetada:
      hasChanges = true
      rpc.partsMetadata = partsMetada
      peerState.partsMetadata = partsMetada

    # if there are any changes send RPC
    if hasChanges:
      ext.sendRPC(peer, rpc)

  var publishedToCount: int = 0

  let peers = ext.publishToPeers(topic)
  for _, p in peers:
    # peer needs to support this extension (and needs to be nagotiated)
    if not ext.isSupported(p):
      continue

    # publish if peer requested partial for topic
    let peerSubOpt = ext.peerSubs.getOrDefault(PeerTopicKey.new(p, topic))
    if peerSubOpt.requestsPartial:
      publishPartialToPeer(p)
      publishedToCount.inc

    # or node requested partial and peer supports sending partials
    let nodeRequestedPartial = false # TODO
    if nodeRequestedPartial and peerSubOpt.supportsSendingPartial:
      publishPartialToPeer(p)
      publishedToCount.inc

  return publishedToCount

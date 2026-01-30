# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import tables, strutils, chronicles, results
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types, partial_message]

logScope:
  topics = "libp2p partial message"

const
  minHeartbeatsTillEviction = 3
  keyDelimiter = "::"

type
  PublishToPeersProc = proc(topic: string): seq[PeerId] {.gcsafe, raises: [].}
    # implements logic for getting list of peers that should be considered when 
    # publishing to the topic.
    # default implementation is set by gossipsub.

  SendRPCProc =
    proc(peerID: PeerId, rpc: PartialMessageExtensionRPC) {.gcsafe, raises: [].}
    # implements logic for sending PartialMessageExtensionRPC to the peer.
    # default implementation is set by gossipsub.

  IsRequestPartialByNodeProc = proc(topic: string): bool {.gcsafe, raises: [].}
    # implements logic for checking if this node is requesting partial messages
    # for topic.
    # default implementation is set by gossipsub.

  IsSupportedProc = proc(peer: PeerId): bool {.gcsafe, raises: [].}
    # implements logic for checking if peer supports this "partial message" extension.
    # default implementation is set by extensions state.

  ValidateRPCProc =
    proc(rpc: PartialMessageExtensionRPC): Result[void, string] {.gcsafe, raises: [].}
    # implements logic for performing sanity checks on PartialMessageExtensionRPC.
    # when error is returned extension will not proces PartialMessageExtensionRPC.
    # needs to be implemented by application.

  OnIncomingRPCProc =
    proc(peer: PeerId, rpc: PartialMessageExtensionRPC) {.gcsafe, raises: [].}
    # called when PartialMessageExtensionRPC is received and ValidateRPCProc did not return
    # error for this message.
    # needs to be implemented by application.

  PartialMessageExtensionConfig* = object
    # 
    # configuration set by node
    sendRPC*: SendRPCProc
    publishToPeers*: PublishToPeersProc
    isSupported*: IsSupportedProc
    isRequestPartialByNode*: IsRequestPartialByNodeProc

    # configuration set by application
    validateRPC*: ValidateRPCProc
    onIncomingRPC*: OnIncomingRPCProc
    heartbeatsTillEviction*: int

  PeerGroupState = ref object
    partsMetadata: PartsMetadata
    sentPartsMetadata: PartsMetadata

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
    isRequestPartialByNode: IsRequestPartialByNodeProc
    validateRPC: ValidateRPCProc
    onIncomingRPC: OnIncomingRPCProc
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
    T: typedesc[TopicGroupKey], topic: string, groupId: GroupId
): TopicGroupKey {.inline.} =
  topic & keyDelimiter & cast[string](groupId)

proc new*(
    T: typedesc[PartialMessageExtension], config: PartialMessageExtensionConfig
): PartialMessageExtension =
  doAssert(config.sendRPC != nil, "config.sendRPC must be set")
  doAssert(config.publishToPeers != nil, "config.publishToPeers must be set")
  doAssert(config.isSupported != nil, "config.isSupported must be set")
  doAssert(
    config.isRequestPartialByNode != nil, "config.isRequestPartialByNode must be set"
  )
  doAssert(config.validateRPC != nil, "config.validateRPC must be set")
  doAssert(config.onIncomingRPC != nil, "config.onIncomingRPC must be set")

  PartialMessageExtension(
    sendRPC: config.sendRPC,
    publishToPeers: config.publishToPeers,
    isSupported: config.isSupported,
    isRequestPartialByNode: config.isRequestPartialByNode,
    validateRPC: config.validateRPC,
    onIncomingRPC: config.onIncomingRPC,
    heartbeatsTillEviction:
      max(config.heartbeatsTillEviction, minHeartbeatsTillEviction),
  )

proc reduceHeartbeatsTillEviction(ext: PartialMessageExtension) =
  # reduce heartbeatsTillEviction and remove groups that hit 0
  var toRemove: seq[TopicGroupKey] = @[]
  for key, group in ext.groupState:
    group.heartbeatsTillEviction.dec
    if group.heartbeatsTillEviction <= 0:
      toRemove.add(key)
  for key in toRemove:
    ext.groupState.del(key)

proc getGroupState(
    ext: PartialMessageExtension, topic: string, groupId: GroupId
): GroupState =
  let key = TopicGroupKey.new(topic, groupId)
  return ext.groupState.mgetOrPut(key, GroupState())

proc getPeerState(gs: GroupState, peerId: PeerId): PeerGroupState =
  return gs.peerState.mgetOrPut(peerId, PeerGroupState())

proc gossipThePartsMetadata(ext: PartialMessageExtension) =
  # TODO: `partsMetadata` can be used during heartbeat gossip to inform non-mesh topic
  # peers about parts this node has.
  discard

proc peerRequestsPartial*(
    ext: PartialMessageExtension, peerId: PeerId, topic: string
): bool =
  let peerSubOpt = ext.peerSubs.getOrDefault(PeerTopicKey.new(peerId, topic))
  return peerSubOpt.requestsPartial

method isSupported*(
    ext: PartialMessageExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.partialMessageExtension

method onHeartbeat*(ext: PartialMessageExtension) {.gcsafe, raises: [].} =
  ext.reduceHeartbeatsTillEviction()
  ext.gossipThePartsMetadata()

method onNegotiated*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  discard # NOOP

method onRemovePeer*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  # remove peer data from _groupState_
  for key, group in ext.groupState:
    group.peerState.del(peerId)

  # remove peer subscription options from _peerSubs_
  var toRemove: seq[PeerTopicKey] = @[]
  for key, _ in ext.peerSubs:
    if key.hasPeer(peerId):
      toRemove.add(key)
  for key in toRemove:
    ext.groupState.del(key)

proc handleSubscribeRPC(ext: PartialMessageExtension, peerId: PeerId, rpc: SubOpts) =
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

proc handlePartialRPC(
    ext: PartialMessageExtension, peerId: PeerId, rpc: PartialMessageExtensionRPC
) =
  let result = ext.validateRPC(rpc)
  if result.isErr():
    debug "Partial message extensions received invalid RPC", msg = result.error
    return

  if rpc.partsMetadata.len > 0:
    var groupState = ext.getGroupState(rpc.topicID, rpc.groupID)
    var peerState = groupState.getPeerState(peerId)
    peerState.partsMetadata = merge(peerState.partsMetadata, rpc.partsMetadata)

  ext.onIncomingRPC(peerId, rpc)

method onHandleRPC*(
    ext: PartialMessageExtension, peerId: PeerId, rpc: RPCMsg
) {.gcsafe, raises: [].} =
  for subRPC in rpc.subscriptions:
    ext.handleSubscribeRPC(peerId, subRPC)

  rpc.partialMessageExtension.withValue(partialExtRPC):
    ext.handlePartialRPC(peerId, partialExtRPC)

proc publishPartial*(
    ext: PartialMessageExtension, topic: string, pm: PartialMessage
): int {.raises: [].} =
  let msgGroupId = pm.groupId()
  let msgPartsMetadata = pm.partsMetadata()
  var groupState = ext.getGroupState(topic, msgGroupId)

  groupState.heartbeatsTillEviction = ext.heartbeatsTillEviction

  proc publishPartialToPeer(peer: PeerId, peerRequestsPartial: bool) {.raises: [].} =
    var rpc = PartialMessageExtensionRPC(topicID: topic, groupID: msgGroupId)
    var peerState = groupState.getPeerState(peer)
    var hasChanges: bool = false

    # if partsMetadata was changed, rpc sets new metadata 
    if peerState.sentPartsMetadata != msgPartsMetadata:
      hasChanges = true
      rpc.partsMetadata = msgPartsMetadata.data
      peerState.sentPartsMetadata = msgPartsMetadata

    # if peer has requested partial messages, attempt to fulfill any 
    # parts that peer is missing.
    if peerRequestsPartial:
      let result = pm.materializeParts(peerState.partsMetadata)
      if result.isErr():
        # there might be error with last PartsMetadata so it is discarded,
        # to avoid any error with future messages.
        peerState.partsMetadata = newSeq[byte](0)
      else:
        peerState.partsMetadata = merge(peerState.partsMetadata, msgPartsMetadata)

        let data = result.get()
        rpc.partialMessage = data
        hasChanges = hasChanges or data.len > 0

    # if there are any changes send RPC
    if hasChanges:
      ext.sendRPC(peer, rpc)

  var publishedToCount: int = 0
  let peers = ext.publishToPeers(topic)
  for _, p in peers:
    # peer needs to support this extension
    if not ext.isSupported(p):
      continue

    let peerSubOpt = ext.peerSubs.getOrDefault(PeerTopicKey.new(p, topic))

    # publish partial message if ...
    if peerSubOpt.requestsPartial:
      # 1) peer requested partial for topic (peer wants to receive partial message)
      publishPartialToPeer(p, true)
      publishedToCount.inc
    elif peerSubOpt.supportsSendingPartial and ext.isRequestPartialByNode(topic):
      # 2) peer supports sending partial for topic and
      # this node wants to receive partial message for this topic.
      publishPartialToPeer(p, false)
      publishedToCount.inc

  return publishedToCount

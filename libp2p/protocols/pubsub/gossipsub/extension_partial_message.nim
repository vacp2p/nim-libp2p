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

  TopicOpts* = object
    requestsPartial*: bool
    supportsSendingPartial*: bool

  NodeTopicOptsProc = proc(topic: string): TopicOpts {.gcsafe, raises: [].}
    # implements logic for getting this node's partial messages preference for topic.
    # default implementation is set by gossipsub.

  IsSupportedProc = proc(peer: PeerId): bool {.gcsafe, raises: [].}
    # implements logic for checking if peer supports this "partial message" extension.
    # default implementation is set by extensions state.

  ValidateRPCProc =
    proc(rpc: PartialMessageExtensionRPC): Result[void, string] {.gcsafe, raises: [].}
    # implements logic for performing sanity checks on PartialMessageExtensionRPC.
    # when error is returned extension will not process PartialMessageExtensionRPC.
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
    nodeTopicOpts*: NodeTopicOptsProc

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

  PeerTopicKey = string
  TopicGroupKey = string

  PartialMessageExtension* = ref object of Extension
    sendRPC: SendRPCProc
    publishToPeers: PublishToPeersProc
    isSupported: IsSupportedProc
    nodeTopicOpts: NodeTopicOptsProc
    validateRPC: ValidateRPCProc
    onIncomingRPC: OnIncomingRPCProc
    heartbeatsTillEviction: int
    groupState: Table[TopicGroupKey, GroupState]
    peerTopicOpts: Table[PeerTopicKey, TopicOpts]

proc new(
    T: typedesc[PeerTopicKey], peerId: PeerId, topic: string
): PeerTopicKey {.inline.} =
  $peerId & keyDelimiter & topic

proc hasPeer(key: PeerTopicKey, peerId: PeerId): bool =
  return ($peerId & keyDelimiter) in key

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
  doAssert(config.nodeTopicOpts != nil, "config.nodeTopicOpts must be set")
  doAssert(config.validateRPC != nil, "config.validateRPC must be set")
  doAssert(config.onIncomingRPC != nil, "config.onIncomingRPC must be set")

  PartialMessageExtension(
    sendRPC: config.sendRPC,
    publishToPeers: config.publishToPeers,
    isSupported: config.isSupported,
    nodeTopicOpts: config.nodeTopicOpts,
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
  let opt = ext.peerTopicOpts.getOrDefault(PeerTopicKey.new(peerId, topic))
  return opt.requestsPartial

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

  # remove peer subscription options from _peerTopicOpts_
  var toRemove: seq[PeerTopicKey] = @[]
  for key, _ in ext.peerTopicOpts:
    if key.hasPeer(peerId):
      toRemove.add(key)
  for key in toRemove:
    ext.peerTopicOpts.del(key)

proc handleSubscribeRPC(ext: PartialMessageExtension, peerId: PeerId, rpc: SubOpts) =
  let key = PeerTopicKey.new(peerId, rpc.topic)
  if rpc.subscribe:
    let rp = rpc.requestsPartial.valueOr:
      false
    let ssp = rpc.supportsSendingPartial.valueOr:
      false

    ext.peerTopicOpts[key] = TopicOpts(
      requestsPartial: rp,
      supportsSendingPartial: rp or ssp,
        # when peer requested partial, then, by spec, they must support it
    )
  else:
    ext.peerTopicOpts.del(key)

proc handlePartialRPC(
    ext: PartialMessageExtension, peerId: PeerId, rpc: PartialMessageExtensionRPC
) =
  let validateRes = ext.validateRPC(rpc)
  if validateRes.isErr():
    debug "Partial message extensions received invalid RPC", msg = validateRes.error
    return

  if rpc.partsMetadata.len > 0:
    var groupState = ext.getGroupState(rpc.topicID, rpc.groupID)
    var peerState = groupState.getPeerState(peerId)
    peerState.partsMetadata = rpc.partsMetadata

  ext.onIncomingRPC(peerId, rpc)

method onHandleRPC*(
    ext: PartialMessageExtension, peerId: PeerId, rpc: RPCMsg
) {.gcsafe, raises: [].} =
  for subRPC in rpc.subscriptions:
    ext.handleSubscribeRPC(peerId, subRPC)

  rpc.partialMessageExtension.withValue(partialExtRPC):
    ext.handlePartialRPC(peerId, partialExtRPC)

proc publishPartialToPeer(
    ext: PartialMessageExtension,
    topic: string,
    pm: PartialMessage,
    groupState: GroupState,
    peer: PeerId,
    peerRequestsPartial: bool,
) {.raises: [].} =
  let msgPartsMetadata = pm.partsMetadata()
  var rpc = PartialMessageExtensionRPC(topicID: topic, groupID: pm.groupId())
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
    let materializeRes = pm.materializeParts(peerState.partsMetadata)
    if materializeRes.isErr():
      # there might be error with last PartsMetadata so it is discarded,
      # to avoid any error with future messages.
      peerState.partsMetadata = newSeq[byte](0)
    else:
      peerState.partsMetadata = union(peerState.partsMetadata, msgPartsMetadata)

      let data = materializeRes.get()
      rpc.partialMessage = data
      hasChanges = hasChanges or data.len > 0

  # if there are any changes send RPC
  if hasChanges:
    ext.sendRPC(peer, rpc)

proc publishPartial*(
    ext: PartialMessageExtension, topic: string, pm: PartialMessage
): int {.raises: [].} =
  var groupState = ext.getGroupState(topic, pm.groupId())

  groupState.heartbeatsTillEviction = ext.heartbeatsTillEviction

  var publishedToCount: int = 0
  let peers = ext.publishToPeers(topic)
  for _, p in peers:
    # peer needs to support this extension
    if not ext.isSupported(p):
      continue

    let peerSubOpt = ext.peerTopicOpts.getOrDefault(PeerTopicKey.new(p, topic))
    let nodeSubOpt = ext.nodeTopicOpts(topic)

    # publish partial message to peer if ...
    if peerSubOpt.requestsPartial and
        (nodeSubOpt.supportsSendingPartial or nodeSubOpt.requestsPartial):
      # 1) peer has requested partial messages for this topic
      ext.publishPartialToPeer(topic, pm, groupState, p, true)
      publishedToCount.inc
    elif nodeSubOpt.requestsPartial and
        (peerSubOpt.supportsSendingPartial or peerSubOpt.requestsPartial):
      # 2) this node has requested partial messages and peer (other node) supports sending it
      ext.publishPartialToPeer(topic, pm, groupState, p, false)
      publishedToCount.inc

  return publishedToCount

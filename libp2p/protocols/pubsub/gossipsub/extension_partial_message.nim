# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import tables, strutils, chronicles, results
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types, partial_message]

logScope:
  topics = "libp2p partial message"

const keyDelimiter = "::"

type
  TopicOpts* = object
    requestsPartial*: bool
    supportsSendingPartial*: bool

  PartialMessageExtensionConfig* = object
    # PartialMessageExtensionConfig hold all configuration need for partial message extension.

    # configuration set by node
    sendRPC*:
      proc(peerID: PeerId, rpc: PartialMessageExtensionRPC) {.gcsafe, raises: [].}
      # implements logic for sending PartialMessageExtensionRPC to the peer.
      # default implementation is set by GossipSub.createExtensionsState.
    publishToPeers*: proc(topic: string): seq[PeerId] {.gcsafe, raises: [].}
      # implements logic for getting list of peers that should be considered when 
      # publishing to the topic.
      # default implementation is set by GossipSub.createExtensionsState.
    nodeTopicOpts*: proc(topic: string): TopicOpts {.gcsafe, raises: [].}
      # implements logic for getting this node's partial messages preference for topic.
      # default implementation is set by GossipSub.createExtensionsState.
    isSupported*: proc(peer: PeerId): bool {.gcsafe, raises: [].}
      # implements logic for checking if peer supports this extension ("partial message").
      # default implementation is set by ExtensionsState.new.

    # configuration set by application (user)
    unionPartsMetadata*:
      proc(a, b: PartsMetadata): Result[PartsMetadata, string] {.gcsafe, raises: [].}
      # creates union of two PartsMetadata and returns it.
      # needs to be implemented by application.
    validateRPC*:
      proc(rpc: PartialMessageExtensionRPC): Result[void, string] {.gcsafe, raises: [].}
      # implements logic for performing sanity checks on PartialMessageExtensionRPC.
      # when error is returned extension will not process PartialMessageExtensionRPC.
      # needs to be implemented by application.
    onIncomingRPC*:
      proc(peer: PeerId, rpc: PartialMessageExtensionRPC) {.gcsafe, raises: [].}
      # called when PartialMessageExtensionRPC is received and ValidateRPCProc did not return
      # error for this message.
      # needs to be implemented by application.
    heartbeatsTillEviction*: int
      # number of heartbeats for which metadata will be retained before eviction

  PeerGroupState = ref object
    peerSentMetadata: bool
      # partial message should be sent only after user seek by sending some metadata.
    partsMetadata: PartsMetadata
    sentPartsMetadata: PartsMetadata

  GroupState = ref object
    peerState: Table[PeerId, PeerGroupState]
    heartbeatsTillEviction: int

  PeerTopicKey = string
  TopicGroupKey = string

  PartialMessageExtension* = ref object of Extension
    config: PartialMessageExtensionConfig
    groupState: Table[TopicGroupKey, GroupState]
    peerTopicOpts: Table[PeerTopicKey, TopicOpts]

proc new(
    T: typedesc[PeerTopicKey], peerId: PeerId, topic: string
): PeerTopicKey {.inline.} =
  $peerId & keyDelimiter & topic

template hasPeer(key: PeerTopicKey, peerId: PeerId): bool =
  ($peerId & keyDelimiter) in key

proc new(
    T: typedesc[TopicGroupKey], topic: string, groupId: GroupId
): TopicGroupKey {.inline.} =
  topic & keyDelimiter & $groupId

proc doAssert(config: PartialMessageExtensionConfig) =
  proc msg(arg: string): string =
    return "PartialMessageExtensionConfig." & arg & " must be set"

  doAssert(config.sendRPC != nil, msg("sendRPC"))
  doAssert(config.publishToPeers != nil, msg("publishToPeers"))
  doAssert(config.isSupported != nil, msg("isSupported"))
  doAssert(config.nodeTopicOpts != nil, msg("nodeTopicOpts"))
  doAssert(config.unionPartsMetadata != nil, msg("unionPartsMetadata"))
  doAssert(config.validateRPC != nil, msg("validateRPC"))
  doAssert(config.onIncomingRPC != nil, msg("onIncomingRPC"))
  doAssert(config.heartbeatsTillEviction >= 1, msg("heartbeatsTillEviction"))

proc new*(
    T: typedesc[PartialMessageExtension], config: PartialMessageExtensionConfig
): PartialMessageExtension =
  config.doAssert()
  PartialMessageExtension(config: config)

proc reduceHeartbeatsTillEviction(ext: PartialMessageExtension) =
  # reduce heartbeatsTillEviction and remove groups that hit 0
  var toRemove: seq[TopicGroupKey] = @[]
  for key, group in ext.groupState.mpairs:
    group.heartbeatsTillEviction.dec
    if group.heartbeatsTillEviction <= 0:
      toRemove.add(key)
  for key in toRemove:
    ext.groupState.del(key)

template getGroupState(
    ext: PartialMessageExtension, topic: string, groupId: GroupId
): GroupState =
  ext.groupState.mgetOrPut(TopicGroupKey.new(topic, groupId), GroupState())

template getPeerState(gs: GroupState, peerId: PeerId): PeerGroupState =
  gs.peerState.mgetOrPut(peerId, PeerGroupState())

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

    if rp or ssp:
      # store only if peer requests or supports sending partial
      # because absence of information results in default values TopicOpts()
      # that has same values as if both properties are false.
      ext.peerTopicOpts[key] =
        TopicOpts(requestsPartial: rp, supportsSendingPartial: ssp)
  else:
    ext.peerTopicOpts.del(key)

proc handlePartialRPC(
    ext: PartialMessageExtension, peerId: PeerId, rpc: PartialMessageExtensionRPC
) =
  let validateRes = ext.config.validateRPC(rpc)
  if validateRes.isErr():
    debug "Partial message extensions received invalid RPC", msg = validateRes.error
    return

  if rpc.partsMetadata.len > 0:
    var groupState = ext.getGroupState(rpc.topicID, rpc.groupID)
    var peerState = groupState.getPeerState(peerId)
    peerState.partsMetadata = rpc.partsMetadata
    peerState.peerSentMetadata = true
    groupState.heartbeatsTillEviction = ext.config.heartbeatsTillEviction

  ext.config.onIncomingRPC(peerId, rpc)

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
    groupState: var GroupState,
    peer: PeerId,
    peerRequestsPartial: bool,
): bool {.raises: [].} =
  let msgPartsMetadata = pm.partsMetadata()
  var rpc = PartialMessageExtensionRPC(topicID: topic, groupID: pm.groupId())
  var peerState = groupState.getPeerState(peer)
  var hasChanges: bool = false

  # if partsMetadata was changed, rpc sets new metadata 
  if peerState.sentPartsMetadata != msgPartsMetadata:
    hasChanges = true
    rpc.partsMetadata = msgPartsMetadata
    peerState.sentPartsMetadata = msgPartsMetadata

  # if peer has requested partial messages, attempt to fulfill any 
  # parts that peer is missing.
  if peerRequestsPartial and peerState.peerSentMetadata:
    let materializeRes = pm.materializeParts(peerState.partsMetadata)
    if materializeRes.isErr():
      # there might be error with last PartsMetadata so it is discarded,
      # to avoid any error with future messages.
      peerState.partsMetadata = newSeq[byte](0)
    else:
      let unionRes =
        ext.config.unionPartsMetadata(peerState.partsMetadata, msgPartsMetadata)
      if unionRes.isErr():
        debug "failed to create union from to parts metadata", msg = unionRes.error
      else:
        peerState.partsMetadata = unionRes.get()

      let data = materializeRes.get()
      rpc.partialMessage = data
      hasChanges = hasChanges or data.len > 0

  # if there are any changes send RPC
  if hasChanges:
    ext.config.sendRPC(peer, rpc)

  return hasChanges # aka has published

proc publishPartial*(
    ext: PartialMessageExtension, topic: string, pm: PartialMessage
): int {.raises: [].} =
  var groupState = ext.getGroupState(topic, pm.groupId())
  groupState.heartbeatsTillEviction = ext.config.heartbeatsTillEviction

  var publishedToCount: int = 0
  let peers = ext.config.publishToPeers(topic)
  for _, p in peers:
    if not ext.config.isSupported(p):
      # peer needs to support this extension
      continue

    let peerSubOpt = ext.peerTopicOpts.getOrDefault(PeerTopicKey.new(p, topic))
    let nodeSubOpt = ext.config.nodeTopicOpts(topic)

    # publish partial message to peer if ...
    if peerSubOpt.requestsPartial and
        (nodeSubOpt.supportsSendingPartial or nodeSubOpt.requestsPartial):
      # 1) peer has requested partial messages for this topic
      if ext.publishPartialToPeer(topic, pm, groupState, p, true):
        publishedToCount.inc
    elif nodeSubOpt.requestsPartial and
        (peerSubOpt.supportsSendingPartial or peerSubOpt.requestsPartial):
      # 2) this node has requested partial messages and peer (other node) supports sending it
      if ext.publishPartialToPeer(topic, pm, groupState, p, false):
        publishedToCount.inc

  return publishedToCount

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import tables
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types, partial_message]

type
  SendRPCProc =
    proc(peerID: PeerId, rpc: PartialMessageExtensionRPC) {.gcsafe, raises: [].}
  PublishToPeersProc = proc(topic: string): seq[PeerId] {.gcsafe, raises: [].}
  IsSupportedProc = proc(peer: PeerId): bool {.gcsafe, raises: [].}

  PartialMessageExtensionConfig* = object
    sendRPC*: SendRPCProc
    publishToPeers*: PublishToPeersProc
    isSupported*: IsSupportedProc

  PeerGroupState = ref object
    partsMetadata: seq[byte]

  GroupState = ref object
    peerState: Table[PeerId, PeerGroupState]

  SubState = ref object
    requestsPartial: bool
    supportsSendingPartial: bool

  PeerTopicKey = string

  PartialMessageExtension* = ref object of Extension
    sendRPC: SendRPCProc
    publishToPeers: PublishToPeersProc
    isSupported: IsSupportedProc
    groupState: Table[string, GroupState]
    peerSubs: Table[PeerTopicKey, SubState]

proc new(
    T: typedesc[PeerTopicKey], peerId: PeerId, topic: string
): PeerTopicKey {.inline.} =
  $peerId & "::" & topic

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
  )

method isSupported*(
    ext: PartialMessageExtension, pe: PeerExtensions
): bool {.gcsafe, raises: [].} =
  return pe.partialMessageExtension

method onHeartbeat*(ext: PartialMessageExtension) {.gcsafe, raises: [].} =
  discard # TODO

method onNegotiated*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  discard # TODO

method onRemovePeer*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  discard # TODO

method onHandleControlRPC*(
    ext: PartialMessageExtension, peerId: PeerId
) {.gcsafe, raises: [].} =
  discard # TODO

proc onSubscribe*(
    ext: PartialMessageExtension,
    peerId: PeerId,
    topic: string,
    subscribe: bool,
    requestsPartial: Option[bool],
    supportsSendingPartial: Option[bool],
) =
  let key = PeerTopicKey.new(peerId, topic)
  if subscribe:
    let rp = requestsPartial.valueOr:
      false
    let ssp = supportsSendingPartial.valueOr:
      false

    ext.peerSubs[key] = SubState(
      requestsPartial: rp,
      supportsSendingPartial: rp or ssp,
        # when peer requested partial, then they must support it
    )
  else:
    ext.peerSubs.del(key)

proc getGroupState(
    ext: PartialMessageExtension, topic: string, groupID: seq[byte]
): GroupState =
  let key = topic & "::" & cast[string](groupID)

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
) {.raises: [].} =
  let groupID = pm.groupID()
  let partsMetada = pm.partsMetadata()
  let groupState = ext.getGroupState(topic, groupID)

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

  let peers = ext.publishToPeers(topic)
  for _, p in peers:
    if not ext.isSupported(p):
      continue

    let subopt = ext.peerSubs.getOrDefault(PeerTopicKey.new(p, topic))
    if subopt.requestsPartial:
      publishPartialToPeer(p)

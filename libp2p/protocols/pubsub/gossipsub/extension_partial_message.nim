# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import tables
import ../../../[peerid]
import ../rpc/messages
import ./[extensions_types, partial_message]

type
  PartialMessageGossipsub* = object # interface

  PartialMessageExtensionConfig* = object
    gossipsub*: PartialMessageGossipsub

  PeerState = ref object
    partsMetadata: seq[byte]

  GroupState = ref object
    peerState: Table[PeerId, PeerState]

  PartialMessageExtension* = ref object of Extension
    gossipsub: PartialMessageGossipsub
    groupState: Table[string, GroupState]

method mashPeers*(
    g: PartialMessageGossipsub, topic: string
): seq[PeerId] {.base, gcsafe, raises: [].} =
  raiseAssert "Should be implemented"

method sendRPC*(
    g: PartialMessageGossipsub, peerID: PeerId, rpc: PartialMessageExtensionRPC
) {.base, gcsafe, raises: [].} =
  raiseAssert "Should be implemented"

proc new*(
    T: typedesc[PartialMessageExtension], config: PartialMessageExtensionConfig
): PartialMessageExtension =
  PartialMessageExtension(gossipsub: config.gossipsub)

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

proc getGroupState(
    ext: PartialMessageExtension, topic: string, groupID: seq[byte]
): GroupState =
  let key = topic & "::" & cast[string](groupID)

  if key notin ext.groupState:
    ext.groupState[key] = GroupState()

  try:
    return ext.groupState[key]
  except KeyError:
    discard # can never happen

proc getPeerState(gs: GroupState, peerId: PeerId): PeerState =
  if peerId notin gs.peerState:
    gs.peerState[peerId] = PeerState()

  try:
    return gs.peerState[peerId]
  except KeyError:
    discard # can never happen

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
      ext.gossipsub.sendRPC(peer, rpc)

  let peers = ext.gossipsub.mashPeers(topic)
  for _, p in peers:
    publishPartialToPeer(p)

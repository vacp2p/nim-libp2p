# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import algorithm, sequtils, std/tables
import ../../[peerid, peerinfo]
import ./[protobuf, types]

type
  LookupNode* = object
    peerId: PeerId
    distance: XorDistance
    queried: bool # have we already queried this node?
    pending: bool # is there an active request rn?
    failed: bool # did the query timeout or error?

  LookupState* = object
    pid: PeerId
    addrTable*: Table[PeerId, seq[MultiAddress]]
    targetId: Key
    shortlist: seq[LookupNode] # current known closest node
    activeQueries*: int # how many queries in flight
    alpha: int # parallelism level
    replication: int ## aka `k`: number of closest nodes to find

proc alreadyInShortlist(state: LookupState, peer: Peer): bool =
  return state.shortlist.anyIt(it.peerId.getBytes() == peer.id)

proc updateShortlist*(
    state: var LookupState, msg: Message, hasher: Opt[XorDHasher]
): seq[PeerInfo] {.raises: [].} =
  var newPeerInfos: seq[PeerInfo]

  for newPeer in msg.closerPeers.filterIt(not alreadyInShortlist(state, it)):
    let peerInfo = PeerInfo(peerId: PeerId.init(newPeer.id).get(), addrs: newPeer.addrs)
    newPeerInfos.add(peerInfo)

    state.shortlist.add(
      LookupNode(
        peerId: peerInfo.peerId,
        distance: xorDistance(peerInfo.peerId, state.targetId, hasher),
        queried: false,
        pending: false,
        failed: false,
      )
    )

  state.shortlist.sort(
    proc(a, b: LookupNode): int =
      cmp(a.distance, b.distance)
  )

  state.activeQueries.dec

  return newPeerInfos

proc markFailed*(state: var LookupState, peerId: PeerId) =
  for p in mitems(state.shortlist):
    if p.peerId == peerId:
      p.failed = true
      p.pending = false
      p.queried = true
      state.activeQueries.dec
      break

proc markPending*(state: var LookupState, peerId: PeerId) =
  for p in mitems(state.shortlist):
    if p.peerId == peerId:
      p.pending = true
      p.queried = true
      break

proc selectAlphaPeers*(state: LookupState): seq[PeerId] =
  var selected: seq[PeerId] = @[]
  for p in state.shortlist:
    if not p.queried and not p.failed and not p.pending and p.peerId != state.pid:
      selected.add(p.peerId)
      if selected.len >= state.alpha:
        break
  return selected

proc init*(
    T: type LookupState,
    pid: PeerId,
    targetId: Key,
    addrTable: Table[PeerId, seq[MultiAddress]],
    alpha: int,
    replication: int,
    hasher: Opt[XorDHasher],
): T =
  var res = LookupState(
    pid: pid,
    targetId: targetId,
    addrTable: addrTable,
    shortlist: @[],
    activeQueries: 0,
    alpha: alpha,
    replication: replication,
  )
  for pid in addrTable.keys():
    res.shortlist.add(
      LookupNode(
        peerId: pid,
        distance: xorDistance(pid, targetId, hasher),
        queried: false,
        pending: false,
        failed: false,
      )
    )

  res.shortlist.sort(
    proc(a, b: LookupNode): int =
      cmp(a.distance, b.distance)
  )
  return res

proc selectClosestK*(state: LookupState): seq[PeerId] =
  var res: seq[PeerId] = @[]
  for p in state.shortlist.filterIt(not it.failed):
    res.add(p.peerId)
    if res.len >= state.replication:
      break
  return res

proc done*(state: LookupState): bool {.raises: [], gcsafe.} =
  let
    ready = state.activeQueries == 0
    noNew = state.selectAlphaPeers().len() == 0

  return ready and noNew

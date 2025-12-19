# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[tables, sequtils, sets, algorithm]
import chronos, chronicles, results
import ../../[peerid, peerinfo, switch, multihash]
import ../protocol
import ./[routingtable, protobuf, types]

type LookupState* = object
  kad: KadDHT
  targetId: Key
  shortlist: Table[PeerId, XorDistance]
  queried: HashSet[PeerId]

proc updateShortlist*(
    state: var LookupState, msg: Message
): seq[PeerInfo] {.raises: [].} =
  var newPeerInfos: seq[PeerInfo]

  for newPeer in msg.closerPeers:
    let pid = PeerId.init(newPeer.id).valueOr:
      continue
    if not state.shortlist.contains(pid):
      state.shortlist[pid] =
        xorDistance(pid, state.targetId, state.kad.rtable.config.hasher)

      let peerInfo = PeerInfo(peerId: pid, addrs: newPeer.addrs)
      newPeerInfos.add(peerInfo)

  return newPeerInfos

proc selectAlphaPeers*(state: LookupState): seq[PeerId] =
  var res: seq[PeerId] = @[]

  let sorted = state.shortlist.pairs().toSeq().sortedByIt(it[1]) # closer distance first

  for (pid, _) in sorted:
    if pid == state.kad.switch.peerInfo.peerId or state.queried.contains(pid):
      continue

    res.add(pid)
    if res.len >= state.kad.config.alpha:
      break

  res

proc init*(T: type LookupState, kad: KadDHT, targetId: Key): T =
  var res = LookupState(kad: kad, targetId: targetId, queried: initHashSet[PeerId]())
  for pid in kad.rtable.findClosestPeerIds(targetId, kad.config.replication):
    res.shortlist[pid] = xorDistance(pid, targetId, kad.rtable.config.hasher)

  return res

proc selectClosestK*(state: LookupState): seq[PeerId] =
  var res: seq[PeerId] = @[]
  for pid in state.shortlist.keys():
    res.add(pid)
    if res.len >= state.kad.config.replication:
      break
  return res

proc done*(state: LookupState): bool {.raises: [], gcsafe.} =
  let noNew = state.selectAlphaPeers().len() == 0

  return noNew

proc dispatchFindNode*(
    switch: Switch,
    peer: PeerId,
    key: Key,
    addrs: Opt[seq[MultiAddress]] = Opt.none(seq[MultiAddress]),
): Future[Message] {.
    async: (raises: [CancelledError, DialFailedError, ValueError, LPStreamError])
.} =
  let addrs = addrs.valueOr(switch.peerStore[AddressBook][peer])
  let conn = await switch.dial(peer, addrs, KadCodec)
  defer:
    await conn.close()

  let msg = Message(msgType: MessageType.findNode, key: key)
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).valueOr:
    raise newException(ValueError, "FindNode reply decode fail")

  return reply

proc updatePeers(kad: KadDHT, peerInfos: seq[PeerInfo]) {.raises: [].} =
  for p in peerInfos:
    discard kad.rtable.insert(p.peerId)
    # Nodes might return different addresses for a peer, so we append instead of replacing
    try:
      var existingAddresses = kad.switch.peerStore[AddressBook][p.peerId].toHashSet()
      for a in p.addrs:
        existingAddresses.incl(a)
      kad.switch.peerStore[AddressBook][p.peerId] = existingAddresses.toSeq()
    except KeyError as exc:
      debug "Could not update shortlist", err = exc.msg
    # TODO: add TTL to peerstore, otherwise we can spam it with junk

proc findNode*(
    kad: KadDHT, key: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  ## Iteratively search for the k closest peers to a key.

  var state = LookupState.init(kad, key)

  while not state.done():
    let toQuery = state.selectAlphaPeers()

    debug "Find node queries", peersToQuery = toQuery.mapIt(it.shortLog())

    let
      rpcBatch = toQuery.mapIt(kad.switch.dispatchFindNode(it, key))
      completedRPCBatch = await rpcBatch.collectCompleted(kad.config.timeout)
    for (fut, peerId) in zip(rpcBatch, toQuery):
      if fut.completed():
        state.queried.incl(peerId)

    for msg in completedRPCBatch:
      for peer in msg.closerPeers:
        let pid = PeerId.init(peer.id)
        if not pid.isOk:
          error "Invalid PeerId in successful reply", peerId = peer.id
          continue
        kad.switch.peerStore[AddressBook][pid.get()] = peer.addrs
      let newPeerInfos = state.updateShortlist(msg)
      kad.updatePeers(newPeerInfos)

  return state.selectClosestK()

proc findPeer*(
    kad: KadDHT, peer: PeerId
): Future[Result[PeerInfo, string]] {.async: (raises: [CancelledError]).} =
  ## Walks the key space until it finds candidate addresses for a peer Id

  if kad.switch.peerInfo.peerId == peer:
    # Looking for yourself.
    return ok(kad.switch.peerInfo)

  if kad.switch.isConnected(peer):
    # Return known info about already connected peer
    return ok(PeerInfo(peerId: peer, addrs: kad.switch.peerStore[AddressBook][peer]))

  let foundNodes = await kad.findNode(peer.toKey())
  if not foundNodes.contains(peer):
    return err("peer not found")

  return ok(PeerInfo(peerId: peer, addrs: kad.switch.peerStore[AddressBook][peer]))

proc findClosestPeers*(kad: KadDHT, target: Key): seq[Peer] =
  var closestPeers: seq[Peer]
  let selfKey = kad.switch.peerInfo.peerId.toKey()
  for p in kad.rtable.findClosest(target, kad.config.replication).filterIt(
    it != selfKey
  ):
    p.toPeer(kad.switch).withValue(peer):
      closestPeers.add(peer)
  return closestPeers

proc handleFindNode*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let targetId = PeerId.init(msg.key).valueOr:
    error "FindNode message without valid key data", msg = msg, conn = conn
    return

  try:
    await conn.writeLp(
      Message(
        msgType: MessageType.findNode,
        closerPeers: kad.findClosestPeers(targetId.toKey()),
      ).encode().buffer
    )
  except LPStreamError as exc:
    debug "Write error when writing kad find-node RPC reply", conn = conn, err = exc.msg
    return

  # Peer is useful. adding to rtable
  discard kad.rtable.insert(conn.peerId)

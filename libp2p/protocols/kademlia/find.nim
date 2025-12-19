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
  targetKey: Key
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
        xorDistance(pid, state.targetKey, state.kad.rtable.config.hasher)

      let peerInfo = PeerInfo(peerId: pid, addrs: newPeer.addrs)
      newPeerInfos.add(peerInfo)

  return newPeerInfos

proc sortedShortlist(state: LookupState): seq[(PeerId, XorDistance)] =
  ## Sort shortlist by closer distance first

  return state.shortlist
    .pairs()
    .toSeq()
    # filter out already queried pids
    .filterIt(not state.queried.contains(it[0]))
    # filter out our own pid
    .filterIt(it[0] != state.kad.switch.peerInfo.peerId)
    # sort by distance (closer first)
    .sortedByIt(it[1])

proc selectPeers*(state: LookupState, amount: int): seq[PeerId] =
  ## Take at most `alpha` peers, sorted by closer peers first
  return state
    .sortedShortlist()
    # get pid
    .mapIt(it[0])
    # take at most alpha peers
    .take(amount)

proc init*(T: type LookupState, kad: KadDHT, targetKey: Key): T =
  var res = LookupState(kad: kad, targetKey: targetKey, queried: initHashSet[PeerId]())
  for pid in kad.rtable.findClosestPeerIds(targetKey, kad.config.replication):
    res.shortlist[pid] = xorDistance(pid, targetKey, kad.rtable.config.hasher)

  return res

proc done*(state: LookupState): bool {.raises: [], gcsafe.} =
  let noNew = state.selectPeers(state.kad.config.alpha).len() == 0

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

proc addNewPeerAddresses(
    addrsTable: SeqPeerBook[MultiAddress], closerPeers: seq[Peer]
) =
  for peer in closerPeers:
    let pid = PeerId.init(peer.id)
    if not pid.isOk:
      error "Invalid PeerId in successful reply", peerId = peer.id
      return
    addrsTable[pid.get()] = peer.addrs

proc findNode*(
    kad: KadDHT, key: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  ## Iteratively search for the k closest peers to a key.

  var state = LookupState.init(kad, key)

  while true:
    let toQuery = state.selectPeers(kad.config.alpha)

    if toQuery.len() == 0:
      break

    debug "Find node queries", peersToQuery = toQuery.mapIt(it.shortLog())

    let
      rpcBatch = toQuery.mapIt(kad.switch.dispatchFindNode(it, key))
      completedRPCBatch = await rpcBatch.collectCompleted(kad.config.timeout)
    for (fut, peerId) in zip(rpcBatch, toQuery):
      if fut.completed():
        state.queried.incl(peerId)

    for msg in completedRPCBatch:
      addNewPeerAddresses(kad.switch.peerStore[AddressBook], msg.closerPeers)
      let newPeerInfos = state.updateShortlist(msg)
      kad.updatePeers(newPeerInfos)

  return state.selectPeers(kad.config.replication)

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
  let closerPeers = kad.rtable.findClosest(target, kad.config.replication).filterIt(
      it != kad.switch.peerInfo.peerId.toKey()
    )

  var closestPeers: seq[Peer]

  for p in closerPeers:
    p.toPeer(kad.switch).withValue(peer):
      closestPeers.add(peer)

  return closestPeers

proc handleFindNode*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let targetKey = PeerId.init(msg.key).valueOr:
    error "FindNode message without valid key data", msg = msg, conn = conn
    return

  try:
    await conn.writeLp(
      Message(
        msgType: MessageType.findNode,
        closerPeers: kad.findClosestPeers(targetKey.toKey()),
      ).encode().buffer
    )
  except LPStreamError as exc:
    debug "Write error when writing kad find-node RPC reply", conn = conn, err = exc.msg
    return

  # Peer is useful. adding to rtable
  discard kad.rtable.insert(conn.peerId)

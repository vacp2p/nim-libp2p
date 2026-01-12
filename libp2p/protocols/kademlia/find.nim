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

logScope:
  topics = "kad-dht find"

type LookupState* = object
  kad: KadDHT
  target*: Key
  shortlist*: Table[PeerId, XorDistance]
  responded*: HashSet[PeerId]
  attempts: Table[PeerId, int]

proc updateShortlist*(
    state: var LookupState, msg: Message
): seq[PeerInfo] {.raises: [].} =
  var newPeerInfos: seq[PeerInfo]

  for newPeer in msg.closerPeers:
    let pid = PeerId.init(newPeer.id).valueOr:
      continue
    if not state.shortlist.contains(pid):
      state.shortlist[pid] =
        xorDistance(pid, state.target, state.kad.rtable.config.hasher)

      let peerInfo = PeerInfo(peerId: pid, addrs: newPeer.addrs)
      newPeerInfos.add(peerInfo)

  return newPeerInfos

proc sortedShortlist(
    state: LookupState, excludeResponded: bool = true
): seq[(PeerId, XorDistance)] =
  ## Sort shortlist by closer distance first
  var sortedShortlist = newSeqOfCap[(PeerId, XorDistance)](state.shortlist.len)

  let selfPid = state.kad.switch.peerInfo.peerId

  for pid, dist in state.shortlist.pairs():
    if pid == selfPid:
      # do not return self
      continue
    if excludeResponded and state.responded.contains(pid):
      # already responded, do not query again
      continue
    if state.attempts.getOrDefault(pid, 0) > state.kad.config.retries:
      # depleted retries, do not query again
      continue
    sortedShortlist.add((pid, dist))

  sortedShortlist.sort(
    proc(a, b: (PeerId, XorDistance)): int =
      cmp(a[1], b[1])
  )

  return sortedShortlist

proc selectCloserPeers*(
    state: LookupState, amount: int, excludeResponded: bool = true
): seq[PeerId] =
  ## Select closer `amount` peers
  return state
    .sortedShortlist(excludeResponded)
    # get pid
    .mapIt(it[0])
    # take at most alpha peers
    .take(amount)

proc init*(T: type LookupState, kad: KadDHT, target: Key): T =
  var res = LookupState(kad: kad, target: target, responded: initHashSet[PeerId]())
  for pid in kad.rtable.findClosestPeerIds(target, kad.config.replication):
    res.shortlist[pid] = xorDistance(pid, target, kad.rtable.config.hasher)

  return res

proc dispatchFindNode*(
    switch: Switch,
    peer: PeerId,
    target: Key,
    addrs: Opt[seq[MultiAddress]] = Opt.none(seq[MultiAddress]),
): Future[Message] {.
    async: (raises: [CancelledError, DialFailedError, ValueError, LPStreamError])
.} =
  let addrs = addrs.valueOr(switch.peerStore[AddressBook][peer])
  let conn = await switch.dial(peer, addrs, KadCodec)
  defer:
    await conn.close()

  let msg = Message(msgType: MessageType.findNode, key: target)
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).valueOr:
    raise newException(ValueError, "FindNode reply decode fail")

  return reply

proc updatePeers*(kad: KadDHT, peerInfos: seq[PeerInfo]) {.raises: [].} =
  for p in peerInfos:
    if kad.rtable.insert(p.peerId):
      kad.switch.peerStore[AddressBook].extend(p.peerId, p.addrs)

proc updatePeers*(kad: KadDHT, peers: seq[(PeerId, seq[MultiAddress])]) {.raises: [].} =
  let peerInfos = peers.mapIt(PeerInfo(peerId: it[0], addrs: it[1]))
  kad.updatePeers(peerInfos)

proc findNode*(
    kad: KadDHT, target: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  ## Iteratively search for the k closest peers to a `target` key.

  var state = LookupState.init(kad, target)

  while true:
    let toQuery = state.selectCloserPeers(kad.config.alpha)

    if toQuery.len() == 0:
      break

    for peerId in toQuery:
      state.attempts[peerId] = state.attempts.getOrDefault(peerId, 0) + 1

    debug "Find node queries", peersToQuery = toQuery.mapIt(it.shortLog())

    let
      rpcBatch = toQuery.mapIt(kad.switch.dispatchFindNode(it, target))
      completedRPCBatch = await rpcBatch.collectCompleted(kad.config.timeout)

    for (fut, peerId) in zip(rpcBatch, toQuery):
      if fut.completed():
        state.responded.incl(peerId)

    for msg in completedRPCBatch:
      let newPeerInfos = state.updateShortlist(msg)
      kad.updatePeers(newPeerInfos)

  return state.selectCloserPeers(kad.config.replication, excludeResponded = false)

proc findPeer*(
    kad: KadDHT, target: PeerId
): Future[Result[PeerInfo, string]] {.async: (raises: [CancelledError]).} =
  ## Walks the key space until it finds candidate addresses for a `target` peer Id

  if kad.switch.peerInfo.peerId == target:
    # Looking for yourself.
    return ok(kad.switch.peerInfo)

  if kad.switch.isConnected(target):
    # Return known info about already connected peer
    return
      ok(PeerInfo(peerId: target, addrs: kad.switch.peerStore[AddressBook][target]))

  let foundNodes = await kad.findNode(target.toKey())
  if not foundNodes.contains(target):
    return err("peer not found")

  return ok(PeerInfo(peerId: target, addrs: kad.switch.peerStore[AddressBook][target]))

proc findClosestPeers*(kad: KadDHT, target: Key): seq[Peer] =
  let closestPeerKeys = kad.rtable.findClosest(target, kad.config.replication).filterIt(
      it != kad.switch.peerInfo.peerId.toKey()
    )

  return kad.switch.toPeers(closestPeerKeys)

proc handleFindNode*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let target = msg.key

  try:
    await conn.writeLp(
      Message(msgType: MessageType.findNode, closerPeers: kad.findClosestPeers(target)).encode().buffer
    )
  except LPStreamError as exc:
    debug "Write error when writing kad find-node RPC reply", conn = conn, err = exc.msg
    return

  # Peer is useful. adding to rtable
  discard kad.rtable.insert(conn.peerId)

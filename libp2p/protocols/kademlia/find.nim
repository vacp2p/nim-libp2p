# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[tables, sequtils, sets]
import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../protocol
import ./[routingtable, lookupstate, protobuf, types]

proc checkConvergence(state: LookupState, me: PeerId): bool {.raises: [], gcsafe.} =
  let ready = state.activeQueries == 0
  let noNew = state.selectAlphaPeers().filterIt(me != it).len == 0
  return ready and noNew

proc waitRepliesOrTimeouts(
    pendingFutures: Table[PeerId, Future[Message]]
): Future[(seq[Message], seq[PeerId])] {.async: (raises: [CancelledError]).} =
  await allFutures(pendingFutures.values.toSeq())

  var receivedReplies: seq[Message] = @[]
  var failedPeers: seq[PeerId] = @[]

  for (peerId, replyFut) in pendingFutures.pairs:
    try:
      receivedReplies.add(await replyFut)
    except CatchableError:
      failedPeers.add(peerId)
      error "Could not send find_node to peer", peerId, err = getCurrentExceptionMsg()

  return (receivedReplies, failedPeers)

proc sendFindNode*(
    kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress], targetId: Key
): Future[Message] {.
    async: (raises: [CancelledError, DialFailedError, ValueError, LPStreamError])
.} =
  let conn = await kad.switch.dial(peerId, addrs, KadCodec)
  defer:
    await conn.close()

  let msg = Message(msgType: MessageType.findNode, key: targetId)
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).tryGet()
  if reply.msgType != MessageType.findNode:
    raise newException(ValueError, "Unexpected reply message type: " & $reply.msgType)

  return reply

proc findNode*(
    kad: KadDHT, targetId: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  ## Iteratively search for the k closest peers to a target ID.

  var initialPeers = kad.rtable.findClosestPeerIds(targetId, kad.config.replication)
  var state = LookupState.init(
    targetId, initialPeers, kad.config.alpha, kad.config.replication,
    kad.rtable.config.hasher,
  )
  var addrTable: Table[PeerId, seq[MultiAddress]]
  for p in initialPeers:
    addrTable[p] = kad.switch.peerStore[AddressBook][p]

  while not state.done:
    let toQuery = state.selectAlphaPeers()
    debug "Find node queries",
      peersToQuery = toQuery.mapIt(it.shortLog()), addressTable = addrTable
    var pendingFutures = initTable[PeerId, Future[Message]]()

    for peer in toQuery.filterIt(kad.switch.peerInfo.peerId != it):
      state.markPending(peer)
      let addrs = addrTable.getOrDefault(peer, @[])
      if addrs.len == 0:
        state.markFailed(peer)
        continue
      pendingFutures[peer] =
        kad.sendFindNode(peer, addrs, targetId).wait(chronos.seconds(5))

      state.activeQueries.inc

    let (successfulReplies, timedOutPeers) = await waitRepliesOrTimeouts(pendingFutures)

    for msg in successfulReplies:
      for peer in msg.closerPeers:
        let pid = PeerId.init(peer.id)
        if not pid.isOk:
          error "Invalid PeerId in successful reply", peerId = peer.id
          continue
        addrTable[pid.get()] = peer.addrs
      state.updateShortlist(
        msg,
        proc(p: PeerInfo) {.raises: [].} =
          discard kad.rtable.insert(p.peerId)
          # Nodes might return different addresses for a peer, so we append instead of replacing
          try:
            var existingAddresses =
              kad.switch.peerStore[AddressBook][p.peerId].toHashSet()
            for a in p.addrs:
              existingAddresses.incl(a)
            kad.switch.peerStore[AddressBook][p.peerId] = existingAddresses.toSeq()
          except KeyError as exc:
            debug "Could not update shortlist", err = exc.msg
          # TODO: add TTL to peerstore, otherwise we can spam it with junk
        ,
        kad.rtable.config.hasher,
      )

    for timedOut in timedOutPeers:
      state.markFailed(timedOut)

    # Check for covergence: no active queries, and no other peers to be selected
    state.done = checkConvergence(state, kad.switch.peerInfo.peerId)

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
  for p in kad.rtable.findClosest(target, kad.config.replication):
    if p == selfKey: # do not return self as one of closest peers
      continue
    let peer = p.toPeer(kad.switch).valueOr:
      continue
    closestPeers.add(peer)
  return closestPeers

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

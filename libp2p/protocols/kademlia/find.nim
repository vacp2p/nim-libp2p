# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sequtils, sets, algorithm]
import chronos, chronicles, results
import ../../[peerid, peerinfo, switch, multihash]
import ../protocol
import ./[routingtable, protobuf, types, kademlia_metrics]

logScope:
  topics = "kad-dht find"

type RespondedStatus* = enum
  Failed
  Success

type LookupState* = object
  kad: KadDHT
  target*: Key
  shortlist*: Table[PeerId, XorDistance]
  responded*: Table[PeerId, RespondedStatus]
  attempts*: Table[PeerId, int]

type DispatchProc* = proc(kad: KadDHT, peer: PeerId, target: Key): Future[Opt[Message]] {.
  async: (raises: [CancelledError, DialFailedError, LPStreamError]), gcsafe
.}

type ReplyHandler* = proc(
  peer: PeerId, msg: Opt[Message], state: var LookupState
): Future[void] {.async: (raises: []), gcsafe.}

type StopCond* = proc(state: LookupState): bool {.raises: [], gcsafe.}

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

proc hasResponsesFromClosestAvailable*(
    state: LookupState
): bool {.raises: [], gcsafe.} =
  ## True when all closest k AVAILABLE peers have responded.
  let candidates = state.sortedShortlist(excludeResponded = false)
  if candidates.len == 0:
    return true

  var closetsRespondedCnt = 0
  for (c, _) in candidates:
    if state.responded.hasKey(c):
      try:
        if state.responded[c] == RespondedStatus.Success:
          closetsRespondedCnt.inc(1)
      except KeyError:
        raiseAssert "checked with hasKey"
    else:
      # It's a close peer but has not been queried yet
      break

  return closetsRespondedCnt >= state.kad.config.replication

proc init*(T: type LookupState, kad: KadDHT, target: Key): T =
  var res = LookupState(kad: kad, target: target)
  for pid in kad.rtable.findClosestPeerIds(target, kad.config.replication):
    res.shortlist[pid] = xorDistance(pid, target, kad.rtable.config.hasher)

  return res

proc dispatchFindNode*(
    kad: KadDHT,
    peer: PeerId,
    target: Key,
    addrs: Opt[seq[MultiAddress]] = Opt.none(seq[MultiAddress]),
): Future[Opt[Message]] {.
    async: (raises: [CancelledError, DialFailedError, LPStreamError]), gcsafe
.} =
  let addrs = addrs.valueOr(kad.switch.peerStore[AddressBook][peer])
  let conn = await kad.switch.dial(peer, addrs, kad.codec)
  defer:
    await conn.close()

  let msg = Message(msgType: MessageType.findNode, key: target)
  let encoded = msg.encode()

  kad_messages_sent.inc(labelValues = [$MessageType.findNode])
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.findNode]
  )

  var replyBuf: seq[byte]
  kad_message_duration_ms.time(labelValues = [$MessageType.findNode]):
    await conn.writeLp(encoded.buffer)
    replyBuf = await conn.readLp(MaxMsgSize)

  kad_message_bytes_received.inc(
    replyBuf.len.int64, labelValues = [$MessageType.findNode]
  )

  let reply = Message.decode(replyBuf).valueOr:
    debug "FindNode reply decode fail", error = error, conn = conn
    return Opt.none(Message)

  if reply.closerPeers.len > 0:
    kad_responses_with_closer_peers.inc(labelValues = [$MessageType.findNode])

  return Opt.some(reply)

proc updatePeers*(kad: KadDHT, peerInfos: seq[PeerInfo]) {.raises: [].} =
  for p in peerInfos:
    if kad.rtable.insert(p.peerId):
      kad.switch.peerStore[AddressBook].extend(p.peerId, p.addrs)

proc updatePeers*(kad: KadDHT, peers: seq[(PeerId, seq[MultiAddress])]) {.raises: [].} =
  let peerInfos = peers.mapIt(PeerInfo(peerId: it[0], addrs: it[1]))
  kad.updatePeers(peerInfos)

proc iterativeLookup*(
    kad: KadDHT,
    target: Key,
    dispatch: DispatchProc,
    onReply: ReplyHandler,
    stopCond: StopCond,
): Future[LookupState] {.async: (raises: [CancelledError]).} =
  var state = LookupState.init(kad, target)

  while true:
    if stopCond(state):
      break

    let toQuery = state.selectCloserPeers(kad.config.alpha)
    if toQuery.len() == 0:
      break

    for peerId in toQuery:
      state.attempts[peerId] = state.attempts.getOrDefault(peerId, 0) + 1

    debug "Lookup queries", peersToQuery = toQuery.mapIt(it.shortLog())

    let dispatchWithPeer = proc(
        peerId: PeerId
    ): Future[(PeerId, Opt[Message])] {.
        async: (raises: [CancelledError, DialFailedError, LPStreamError]), gcsafe
    .} =
      let msg = await dispatch(kad, peerId, target)
      return (peerId, msg)

    let
      rpcBatch = toQuery.mapIt(dispatchWithPeer(it))
      completedRPCBatch = await rpcBatch.collectCompleted(kad.config.timeout)

    for (fut, peerId) in zip(rpcBatch, toQuery):
      if not fut.finished():
        continue
      state.responded[peerId] =
        if fut.failed(): RespondedStatus.Failed else: RespondedStatus.Success

    for (peerId, msg) in completedRPCBatch:
      msg.withValue(reply):
        let newPeerInfos = state.updateShortlist(reply)
        kad.updatePeers(newPeerInfos)
      await onReply(peerId, msg, state)

  return state

method findNode*(
    kad: KadDHT, target: Key, queue = newAsyncQueue[(PeerId, Opt[Message])]()
): Future[seq[PeerId]] {.base, async: (raises: [CancelledError]).} =
  ## Iteratively search for the k closest peers to a `target` key.

  let ignoreReply = proc(
      peerId: PeerId, msgOpt: Opt[Message], _: var LookupState
  ): Future[void] {.async: (raises: []), gcsafe.} =
    let queueRes = catch:
      await queue.addLast((peerId, msgOpt))
    if queueRes.isErr:
      error "failed to queue find node reply", error = queueRes.error.msg

  let stop = proc(state: LookupState): bool {.raises: [], gcsafe.} =
    state.hasResponsesFromClosestAvailable()

  let dispatchFind = proc(
      kad: KadDHT, peer: PeerId, target: Key
  ): Future[Opt[Message]] {.
      async: (raises: [CancelledError, DialFailedError, LPStreamError]), gcsafe
  .} =
    return await dispatchFindNode(kad, peer, target)

  let state = await kad.iterativeLookup(target, dispatchFind, ignoreReply, stop)

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

method handleFindNode*(
    kad: KadDHT, conn: Connection, msg: Message
) {.base, async: (raises: [CancelledError]).} =
  let target = msg.key

  let response =
    Message(msgType: MessageType.findNode, closerPeers: kad.findClosestPeers(target))
  let encoded = response.encode()
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.findNode]
  )
  try:
    await conn.writeLp(encoded.buffer)
  except LPStreamError as exc:
    debug "Write error when writing kad find-node RPC reply", conn = conn, err = exc.msg
    return

  # Peer is useful. adding to rtable
  discard kad.rtable.insert(conn.peerId)

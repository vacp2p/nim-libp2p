# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sequtils, algorithm, net]
import chronos, chronicles, results
import ../../[peerid, peerinfo, switch, multihash, peeraddrpolicy, wire]
import ../protocol
import ../../utils/future
import ./[routing_table, protobuf, types, kademlia_metrics]

logScope:
  topics = "kad-dht find"

type RespondedStatus* = enum
  Failed
  Success

type LookupState* = ref object
  kad: KadDHT
  target*: Key
  shortlist*: Table[PeerId, XorDistance]
  responded*: Table[PeerId, RespondedStatus]
  attempts*: Table[PeerId, int]
  inflight*: Table[PeerId, seq[FutureBase]]

type DispatchProc* = proc(
  kad: KadDHT, peer: PeerId, target: Key
): Future[Result[Message, string]] {.
  async: (raises: [CancelledError]), gcsafe, closure
.}

type ReplyHandler* = proc(
  peer: PeerId, msg: Opt[Message], state: LookupState
): Future[void] {.async: (raises: []), gcsafe.}

type StopCond* = proc(state: LookupState): bool {.raises: [], gcsafe.}

proc getFarthest(
    t: Table[PeerId, XorDistance]
): Opt[(PeerId, XorDistance)] {.raises: [].} =
  var worstPid: PeerId
  var worstDist: XorDistance
  var found = false
  for pid, d in t.pairs():
    if not found or worstDist < d:
      worstPid = pid
      worstDist = d
      found = true
  if found:
    Opt.some((worstPid, worstDist))
  else:
    Opt.none((PeerId, XorDistance))

proc tryEvictFarthest(state: LookupState, newDist: XorDistance): bool {.raises: [].} =
  ## Drop the worst (farthest) peer from the shortlist if it is farther than
  ## ``newDist``. Considers all peers — including ones that already responded —
  ## because the iterative lookup needs the closer candidate to make progress.
  ## A responded peer's contribution is already merged into the shortlist, so
  ## evicting it costs nothing beyond bookkeeping.
  let (pid, dist) = state.shortlist.getFarthest().valueOr:
    return false
  if newDist >= dist:
    return false
  state.shortlist.del(pid)
  state.attempts.del(pid)
  state.responded.del(pid)
  return true

proc updateShortlist*(state: LookupState, msg: Message): seq[PeerInfo] {.raises: [].} =
  var newPeerInfos: seq[PeerInfo]
  let cap = state.kad.config.limits.maxShortlistSize

  for newPeer in msg.closerPeers:
    let raw = newPeer.id.valueOr:
      continue
    let pid = PeerId.init(raw).valueOr:
      continue
    if state.shortlist.contains(pid):
      continue

    let dist = xorDistance(pid, state.target, state.kad.rtable.config.hasher)

    if state.shortlist.len >= cap and not state.tryEvictFarthest(dist):
      continue

    state.shortlist[pid] = dist
    newPeerInfos.add(PeerInfo(peerId: pid, addrs: newPeer.addrs))

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

proc allSortedPeers*(state: LookupState): seq[PeerId] =
  ## Returns all peers discovered during lookup sorted by XOR distance to target (closest first).
  state.sortedShortlist(excludeResponded = false).mapIt(it[0])

proc init*(T: type LookupState, kad: KadDHT, target: Key): T =
  let res = LookupState(kad: kad, target: target)
  for pid in kad.rtable.findClosestPeerIds(target, kad.config.replication):
    res.shortlist[pid] = xorDistance(pid, target, kad.rtable.config.hasher)

  res

proc dispatchFindNode*(
    kad: KadDHT,
    peer: PeerId,
    target: Key,
    addrs: Opt[seq[MultiAddress]] = Opt.none(seq[MultiAddress]),
): Future[Result[Message, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  withRpcSlot(kad)
  let addrs = addrs.valueOr(kad.switch.peerStore[AddressBook][peer])
  let streamRes = catch:
    await kad.switch.dial(peer, addrs, kad.codec)
  if streamRes.isErr:
    return err(streamRes.error.msg)
  let stream = streamRes.value()
  defer:
    await stream.close()

  let msg = Message(msgType: Opt.some(MessageType.findNode), key: Opt.some(target))
  let encoded = msg.encode(kad.config.hideConnectionStatus)

  kad_messages_sent.inc(labelValues = [$MessageType.findNode])
  kad_message_bytes_sent.inc(encoded.len.int64, labelValues = [$MessageType.findNode])

  var replyBuf: seq[byte]
  var ioRes: Result[void, ref CatchableError]
  kad_message_duration_ms.time(labelValues = [$MessageType.findNode]):
    ioRes = catch:
      await stream.writeLp(encoded)
      replyBuf = await stream.readLp(MaxMsgSize)
  if ioRes.isErr:
    return err(ioRes.error.msg)

  kad_message_bytes_received.inc(
    replyBuf.len.int64, labelValues = [$MessageType.findNode]
  )

  let reply = Message.decode(replyBuf).valueOr:
    return err("FindNode reply decode fail")

  if reply.closerPeers.len > 0:
    kad_responses_with_closer_peers.inc(labelValues = [$MessageType.findNode])

  return ok(reply)

type
  Ipv4Address = array[4, byte]
  Ipv4Subnet24 = array[3, byte]
  Ipv6Address = array[16, byte]
  Ipv6Subnet64 = array[8, byte]

  PeerIps = object
    ipv4s: seq[Ipv4Address]
    ipv6s: seq[Ipv6Address]

proc subnet24(ip: Ipv4Address): Ipv4Subnet24 {.raises: [].} =
  var subnet: Ipv4Subnet24
  subnet[0] = ip[0]
  subnet[1] = ip[1]
  subnet[2] = ip[2]
  subnet

proc subnet64(ip: Ipv6Address): Ipv6Subnet64 {.raises: [].} =
  var subnet: Ipv6Subnet64
  for i in 0 ..< subnet.len:
    subnet[i] = ip[i]
  subnet

proc uniquePublicIps(addrs: seq[MultiAddress]): PeerIps {.raises: [].} =
  # Diversity limits need literal public IPs; private, relay, and DNS addresses
  # either do not represent the remote network directly or cannot be prefix-counted here.
  var peerIps: PeerIps
  for ma in addrs:
    if not ma.isPublicMA():
      continue
    let ip = ma.getIp().valueOr:
      continue
    case ip.family
    of IpAddressFamily.IPv4:
      if ip.address_v4 notin peerIps.ipv4s:
        peerIps.ipv4s.add(ip.address_v4)
    of IpAddressFamily.IPv6:
      if ip.address_v6 notin peerIps.ipv6s:
        peerIps.ipv6s.add(ip.address_v6)
  return peerIps

proc sharesSubnet24(addrs: seq[Ipv4Address], subnet: Ipv4Subnet24): bool =
  for ip in addrs:
    if ip.subnet24() == subnet:
      return true
  false

proc sharesSubnet64(addrs: seq[Ipv6Address], subnet: Ipv6Subnet64): bool =
  for ip in addrs:
    if ip.subnet64() == subnet:
      return true
  false

proc hasIpDiversity(
    addressBook: AddressBook,
    rtable: RoutingTable,
    peerId: PeerId,
    addrs: seq[MultiAddress],
    maxPeersPerIp: int,
    maxPeersPerIpv4Subnet: int,
    maxPeersPerIpv6Subnet: int,
): bool {.raises: [].} =
  # Existing entries may refresh their addresses; diversity limits apply to new
  # routing-table admission, not to maintenance of already-admitted peers.
  if peerId.toKey() in rtable.allKeys():
    return true

  let candidateIps = addrs.uniquePublicIps()
  # No public literal IP means there is no prefix to count. Let the configured
  # address policy decide whether these addresses are otherwise acceptable.
  if candidateIps.ipv4s.len == 0 and candidateIps.ipv6s.len == 0:
    return true

  let currentKeys = rtable.allKeys()
  # A multi-addressed peer is admissible if at least one public address remains
  # below both its exact-IP and subnet caps.
  for candidateIp in candidateIps.ipv4s:
    let candidateSubnet = candidateIp.subnet24()
    var exactCount = 0
    var subnetCount = 0

    for key in currentKeys:
      let existingPeer = key.toPeerId().valueOr:
        continue
      if existingPeer == peerId:
        continue

      let existingIps = addressBook[existingPeer].uniquePublicIps()
      if candidateIp in existingIps.ipv4s:
        exactCount.inc
      if existingIps.ipv4s.sharesSubnet24(candidateSubnet):
        subnetCount.inc

    if exactCount < maxPeersPerIp and subnetCount < maxPeersPerIpv4Subnet:
      return true

  for candidateIp in candidateIps.ipv6s:
    let candidateSubnet = candidateIp.subnet64()
    var exactCount = 0
    var subnetCount = 0

    for key in currentKeys:
      let existingPeer = key.toPeerId().valueOr:
        continue
      if existingPeer == peerId:
        continue

      let existingIps = addressBook[existingPeer].uniquePublicIps()
      if candidateIp in existingIps.ipv6s:
        exactCount.inc
      if existingIps.ipv6s.sharesSubnet64(candidateSubnet):
        subnetCount.inc

    if exactCount < maxPeersPerIp and subnetCount < maxPeersPerIpv6Subnet:
      return true

  false

proc updatePeers*(
    switch: Switch,
    addressPolicy: PeerAddressPolicy,
    rtable: RoutingTable,
    peerInfos: seq[PeerInfo],
    maxPeersPerIp: int = DefaultMaxPeersPerIp,
    maxPeersPerIpv4Subnet: int = DefaultMaxPeersPerSubnet,
    maxPeersPerIpv6Subnet: int = DefaultMaxPeersPerSubnet,
) {.raises: [].} =
  let addressBook = switch.peerStore[AddressBook]
  for p in peerInfos:
    let addrs = addressPolicy.filterAddrs(p.addrs)
    if addrs.len == 0:
      continue
    if not addressBook.hasIpDiversity(
      rtable, p.peerId, addrs, maxPeersPerIp, maxPeersPerIpv4Subnet,
      maxPeersPerIpv6Subnet,
    ):
      continue
    if rtable.insert(p.peerId):
      addressBook.extend(p.peerId, addrs, AddressConfidence.Low)

proc updatePeers*(kad: KadDHT, peerInfos: seq[PeerInfo]) {.raises: [].} =
  updatePeers(
    kad.switch, kad.config.addressPolicy, kad.rtable, peerInfos,
    kad.config.limits.maxPeersPerIp, kad.config.limits.maxPeersPerIpv4Subnet,
    kad.config.limits.maxPeersPerIpv6Subnet,
  )

proc updatePeers*(kad: KadDHT, peers: seq[(PeerId, seq[MultiAddress])]) {.raises: [].} =
  let peerInfos = peers.mapIt(PeerInfo(peerId: it[0], addrs: it[1]))
  kad.updatePeers(peerInfos)

proc noopReply*(
    peerId: PeerId, msgOpt: Opt[Message], state: LookupState
): Future[void] {.async: (raises: []), gcsafe.} =
  discard

proc closestAvailableStop*(state: LookupState): bool {.raises: [], gcsafe.} =
  state.hasResponsesFromClosestAvailable()

proc findNodeDispatch*(
    kad: KadDHT, peer: PeerId, target: Key
): Future[Result[Message, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  return await dispatchFindNode(kad, peer, target)

proc lookOnce*(
    kad: KadDHT,
    state: LookupState,
    rtable: RoutingTable,
    dispatch: DispatchProc,
    onReply: ReplyHandler,
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Run a single round of the iterative lookup against ``state.target``.
  ## Returns ``false`` when no further peers can be queried, signalling the
  ## caller to stop driving the lookup.
  let toQuery = state.selectCloserPeers(kad.config.alpha)
  if toQuery.len() == 0:
    return false

  for peerId in toQuery:
    state.attempts[peerId] = state.attempts.getOrDefault(peerId, 0) + 1

  debug "Lookup queries", peersToQuery = toQuery.mapIt(it.shortLog())

  let target = state.target
  let dispatchWithPeer = proc(
      peerId: PeerId
  ): Future[(PeerId, Result[Message, string])] {.
      async: (raises: [CancelledError]), gcsafe
  .} =
    let msg = await dispatch(kad, peerId, target)
    return (peerId, msg)

  let rpcBatch = toQuery.mapIt(dispatchWithPeer(it))
  for (fut, peerId) in zip(rpcBatch, toQuery):
    state.inflight.mgetOrPut(peerId, @[]).add(FutureBase(fut))
  let completedRPCBatch = await rpcBatch.collectCompleted(kad.config.timeout)

  for (fut, peerId) in zip(rpcBatch, toQuery):
    if not fut.finished() or fut.cancelled():
      continue
    if fut.failed():
      state.responded[peerId] = RespondedStatus.Failed
    else:
      let (_, res) = fut.value()
      if res.isErr():
        state.responded[peerId] = RespondedStatus.Failed
        error "Kad lookup: RPC error", peer = peerId.shortLog(), msg = res.error()
      else:
        state.responded[peerId] = RespondedStatus.Success

  var toCancel: seq[FutureBase]
  for (peerId, res) in completedRPCBatch:
    let reply = res.valueOr:
      continue
    let newPeerInfos = state.updateShortlist(reply)
    kad.switch.updatePeers(
      kad.config.addressPolicy, rtable, newPeerInfos, kad.config.limits.maxPeersPerIp,
      kad.config.limits.maxPeersPerIpv4Subnet, kad.config.limits.maxPeersPerIpv6Subnet,
    )
    await onReply(peerId, Opt.some(reply), state)

  # Evicted peers are no longer eligible for retries, so cancel any abandoned RPCs.
  for peerId in state.inflight.keys.toSeq:
    if not state.shortlist.hasKey(peerId):
      toCancel.add(state.inflight.getOrDefault(peerId).filterIt(not it.finished()))
      state.inflight.del(peerId)

  for peerId in toQuery:
    if state.responded.hasKey(peerId) or
        state.attempts.getOrDefault(peerId, 0) > kad.config.retries:
      toCancel.add(state.inflight.getOrDefault(peerId).filterIt(not it.finished()))
      state.inflight.del(peerId)
  await toCancel.cancelAndWait()

  return true

proc iterativeLookup*(
    kad: KadDHT,
    target: Key,
    rtable: RoutingTable,
    dispatch: DispatchProc,
    onReply: ReplyHandler,
    stopCond: StopCond,
): Future[LookupState] {.async: (raises: [CancelledError]).} =
  let state = LookupState.init(kad, target)

  while not stopCond(state):
    if not await kad.lookOnce(state, rtable, dispatch, onReply):
      break

  var leftover: seq[FutureBase]
  for futs in state.inflight.values:
    leftover.add(futs.filterIt(not it.finished()))
  if leftover.len > 0:
    await leftover.cancelAndWait()

  state

proc iterativeLookup*(
    kad: KadDHT,
    target: Key,
    dispatch: DispatchProc,
    onReply: ReplyHandler,
    stopCond: StopCond,
): Future[LookupState] {.async: (raises: [CancelledError]).} =
  await kad.iterativeLookup(target, kad.rtable, dispatch, onReply, stopCond)

method findNode*(
    kad: KadDHT, target: Key, rtable: RoutingTable
): Future[seq[PeerId]] {.base, async: (raises: [CancelledError]).} =
  ## Iteratively search for the k closest peers to a `target` key.
  let state = await kad.iterativeLookup(
    target, rtable, findNodeDispatch, noopReply, closestAvailableStop
  )

  return state.selectCloserPeers(kad.config.replication, excludeResponded = false)

method findNode*(
    kad: KadDHT, target: Key
): Future[seq[PeerId]] {.base, async: (raises: [CancelledError]).} =
  await kad.findNode(target, kad.rtable)

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
    kad: KadDHT, stream: Stream, msg: Message
) {.base, async: (raises: [CancelledError]).} =
  let msgKey = msg.key.valueOr:
    error "Key not set: handleFindNode", msg = msg, stream = stream
    return

  let response = Message(
    msgType: Opt.some(MessageType.findNode), closerPeers: kad.findClosestPeers(msgKey)
  )
  let encoded = response.encode(kad.config.hideConnectionStatus)
  kad_message_bytes_sent.inc(encoded.len.int64, labelValues = [$MessageType.findNode])
  try:
    await stream.writeLp(encoded)
  except LPStreamError as exc:
    debug "Write error when writing kad find-node RPC reply",
      stream = stream, err = exc.msg
    return

  # Only admit senders with known dialable addresses; an inbound connection
  # may use an ephemeral source port.
  let addrs = kad.switch.peerStore[AddressBook][stream.peerId]
  if addrs.len > 0:
    kad.updatePeers(@[PeerInfo(peerId: stream.peerId, addrs: addrs)])

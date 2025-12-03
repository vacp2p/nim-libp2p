# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[sets, tables, sequtils]
import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../kademlia/[types, routingtable, lookupstate, protobuf, find, get, protobuf]
import ./types

proc findAllNode*(
    disco: KademliaDiscovery, targetId: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  ## Return all peerIds on the way to a target ID.

  var initialPeers = disco.rtable.findClosestPeerIds(targetId, disco.config.replication)
  var state = LookupState.init(
    targetId, initialPeers, disco.config.alpha, high(int), disco.rtable.config.hasher
  )
  var addrTable: Table[PeerId, seq[MultiAddress]]
  for p in initialPeers:
    addrTable[p] = disco.switch.peerStore[AddressBook][p]

  while not state.done:
    let toQuery = state.selectAlphaPeers()
    debug "Find node queries",
      peersToQuery = toQuery.mapIt(it.shortLog()), addressTable = addrTable
    var pendingFutures = initTable[PeerId, Future[Message]]()

    for peer in toQuery.filterIt(disco.switch.peerInfo.peerId != it):
      state.markPending(peer)
      let addrs = addrTable.getOrDefault(peer, @[])
      if addrs.len == 0:
        state.markFailed(peer)
        continue
      pendingFutures[peer] =
        disco.sendFindNode(peer, addrs, targetId).wait(chronos.seconds(5))

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
          discard disco.rtable.insert(p.peerId)
          # Nodes might return different addresses for a peer, so we append instead of replacing
          try:
            var existingAddresses =
              disco.switch.peerStore[AddressBook][p.peerId].toHashSet()
            for a in p.addrs:
              existingAddresses.incl(a)
            disco.switch.peerStore[AddressBook][p.peerId] = existingAddresses.toSeq()
          except KeyError as exc:
            debug "Could not update shortlist", err = exc.msg
          # TODO: add TTL to peerstore, otherwise we can spam it with junk
        ,
        disco.rtable.config.hasher,
      )

    for timedOut in timedOutPeers:
      state.markFailed(timedOut)

    # Check for covergence: no active queries, and no other peers to be selected
    state.done = checkConvergence(state, disco.switch.peerInfo.peerId)

  return state.selectClosestK()

proc findRandom*(
    disco: KademliaDiscovery
): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
  ## Return all nodes on the path towards a random target ID.

  let randomPeerId = PeerId.random(disco.rng).valueOr:
    debug "cannot generate random peer id", error
    return @[]

  let randomKey = randomPeerId.toKey()

  let queue = newAsyncQueue[(PeerId, Opt[Message])]()
  let findRes = catch:
    await disco.findNode(randomKey, queue)
  if findRes.isErr:
    error "kad find node failed", error = findRes.error.msg

  var buffers: seq[seq[byte]]
  while not queue.empty():
    let (peerId, _) = await queue.popFirst()

    let res = catch:
      await disco.dispatchGetVal(peerId, peerId.toKey())
    let msgOpt = res.valueOr:
      error "kad getValue failed", error = res.error.msg
      continue

    let reply = msgOpt.valueOr:
      continue

    let record = reply.record.valueOr:
      continue

    let buffer = record.value.valueOr:
      continue

    buffers.add(buffer)

  var records: seq[ExtendedPeerRecord]
  for buffer in buffers:
    let sxpr = SignedExtendedPeerRecord.decode(buffer).valueOr:
      debug "cannot decode signed extended peer record", error
      continue

    records.add(sxpr.data)

  return records

proc filterByServices*(
    records: seq[ExtendedPeerRecord], services: HashSet[ServiceInfo]
): seq[ExtendedPeerRecord] =
  records.filterIt(it.services.anyIt(services.contains(it)))

proc lookup*(
    disco: KademliaDiscovery, service: ServiceInfo
): Future[seq[ExtendedPeerRecord]] {.async: (raises: [CancelledError]).} =
  let records = await disco.randomRecords()

  return records.filterByServices(@[service].toHashSet())
  let peerIds = await disco.findNode(randomKey)

  var getFutures: seq[Future[Result[EntryRecord, string]]] = @[]
  for pid in peerIds:
    getFutures.add(disco.getValue(pid.toKey()))

  var records: seq[SignedPeerRecord] = @[]
  await allFutures(getFutures)

  for fut in getFutures:
    if fut.failed:
      trace "future failed", error = fut.error
      continue

    let entry = fut.read().valueOr:
      trace "cannot read future", error
      continue

    let spr = SignedPeerRecord.decode(entry.value).valueOr:
      debug "cannot decode signed peer record", error
      continue

    records.add(spr)

  return records

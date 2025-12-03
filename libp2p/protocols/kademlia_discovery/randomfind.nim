# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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

  let peerIds = await disco.findAllNode(randomKey)

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

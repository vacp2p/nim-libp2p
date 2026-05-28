# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets, heapqueue]
import chronos, chronicles, results
import ../../[peerid, peerinfo, switch, multihash, routing_record, extended_peer_record]
import ../protocol
import ../kademlia/[types, find, get, protobuf, routing_table]
import ./[types]

logScope:
  topics = "ext-kad-dht random records"

proc randomRecords(
    disco: ServiceDiscovery
): Future[seq[ExtendedPeerRecord]] {.async: (raises: [CancelledError]).} =
  ## Return all peer records on the path towards a random target ID.

  let randomPeerId = PeerId.random(disco.rng).valueOr:
    debug "cannot generate random peer id", error
    return @[]

  let randomKey = randomPeerId.toKey()

  let queue = newPeerDistanceHeap()

  let peers = disco.rtable.findClosestPeerIds(randomKey, disco.config.replication)
  for peer in peers:
    let distance = xorDistance(peer, randomKey, disco.rtable.config.hasher)
    queue[].push(PeerDistance(peerId: peer, distance: distance))

  # CancelledError propagates; findNode reports any other failure via logs.
  discard await disco.findNode(randomKey, queue)

  # findNode has finished, so the heap now holds every discovered peer. Drain it
  # closest-first and fetch each peer's value.
  var buffers: seq[seq[byte]]
  while queue[].len > 0:
    let peerId = queue[].pop().peerId

    let reply = (await disco.dispatchGetVal(peerId, peerId.toKey())).valueOr:
      error "kad getValue failed", error = error
      continue

    let record = reply.record.valueOr:
      continue

    let buffer = record.value.valueOr:
      continue

    buffers.add(buffer)

  var records: HashSet[ExtendedPeerRecord]
  for buffer in buffers:
    let sxpr = SignedExtendedPeerRecord.decode(buffer).valueOr:
      debug "cannot decode signed extended peer record", error
      continue

    records.incl(sxpr.data)

  return records.toSeq()

proc lookupRandom*(
    disco: ServiceDiscovery
): Future[seq[ExtendedPeerRecord]] {.async: (raises: [CancelledError]).} =
  return await disco.randomRecords()

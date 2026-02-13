# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets]
import chronos, chronicles, results
import ../../[peerid, peerinfo, switch, multihash, routing_record, extended_peer_record]
import ../protocol
import ../kademlia/[types, find, get, protobuf, routingtable]
import ./[types]

logScope:
  topics = "ext-kad-dht random records"

proc randomRecords*(
    disco: KademliaDiscovery
): Future[seq[ExtendedPeerRecord]] {.async: (raises: [CancelledError]).} =
  ## Return all peer records on the path towards a random target ID.

  let randomPeerId = PeerId.random(disco.rng).valueOr:
    debug "cannot generate random peer id", error
    return @[]

  let randomKey = randomPeerId.toKey()

  let queue = newAsyncQueue[(PeerId, Opt[Message])]()

  let peers = disco.rtable.findClosestPeerIds(randomKey, disco.config.replication)
  for peer in peers:
    let addRes = catch:
      queue.addFirstNoWait((peer, Opt.none(Message)))
    if addRes.isErr:
      error "cannot enqueue peer", error = addRes.error.msg

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

  var records: HashSet[ExtendedPeerRecord]
  for buffer in buffers:
    let sxpr = SignedExtendedPeerRecord.decode(buffer).valueOr:
      debug "cannot decode signed extended peer record", error
      continue

    records.incl(sxpr.data)

  return records.toSeq()

proc filterByServices*(
    records: seq[ExtendedPeerRecord], services: HashSet[ServiceInfo]
): seq[ExtendedPeerRecord] =
  records.filterIt(it.services.anyIt(services.contains(it)))

proc lookup*(
    disco: KademliaDiscovery, service: ServiceInfo
): Future[seq[ExtendedPeerRecord]] {.async: (raises: [CancelledError]).} =
  let records = await disco.randomRecords()

  return records.filterByServices(@[service].toHashSet())

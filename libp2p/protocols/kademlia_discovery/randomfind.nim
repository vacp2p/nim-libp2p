# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[sequtils, sets]
import chronos, chronicles, results
import ../../[peerid, peerinfo, switch, multihash, routing_record, extended_peer_record]
import ../protocol
import ../kademlia/[types, find, get, protobuf]
import ./[types]

logScope:
  topics = "ext-kad-dht random find"

proc findRandom*(
    disco: KademliaDiscovery
): Future[seq[ExtendedPeerRecord]] {.async: (raises: [CancelledError]).} =
  ## Return all peer records on the path towards a random target ID.

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

    let msg = res.valueOr:
      error "Failed to get value", error = res.error.msg
      return

    let reply = msg.valueOr:
      return

    let record = reply.record.valueOr:
      return

    let buffer = record.value.valueOr:
      return

    buffers.add(buffer)

  let stop = proc(state: LookupState): bool {.raises: [], gcsafe.} =
    state.hasResponsesFromClosestAvailable()

  let dispatchFind = proc(
      kad: KadDHT, peer: PeerId, target: Key
  ): Future[Opt[Message]] {.
      async: (raises: [CancelledError, DialFailedError, LPStreamError]), gcsafe
  .} =
    return await dispatchFindNode(kad, peer, target)

  let state = await disco.iterativeLookup(randomKey, dispatchFind, bufferReply, stop)

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
  let records = await disco.findRandom()

  return records.filterByServices(@[service].toHashSet())

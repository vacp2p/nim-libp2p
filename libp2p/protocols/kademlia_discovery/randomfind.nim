# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import chronos, chronicles, results
import ../../[peerid, switch, multihash]
import ../kademlia/[types, find, get]
import ./types

proc findRandom*(
    disco: KademliaDiscovery
): Future[seq[SignedPeerRecord]] {.async: (raises: [CancelledError]).} =
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

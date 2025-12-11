# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[tables, sequtils, sets]
import chronos, chronicles, results
import ../../[peerid, peerinfo, switch, multihash]
import ../protocol
import ../kademlia/[types, find, get, protobuf]
import ./[types, protobuf]

proc findRandom*(
    disco: KademliaDiscovery
): Future[seq[ExtPeerRecord]] {.async: (raises: [CancelledError]).} =
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

  while true:
    let toQuery = state.selectCloserPeers(disco.config.alpha)

    if toQuery.len() == 0:
      break

    for peerId in toQuery:
      state.attempts[peerId] = state.attempts.getOrDefault(peerId, 0) + 1

    debug "Find random node queries", peersToQuery = toQuery.mapIt(it.shortLog())

    let
      findRPCBatch = toQuery.mapIt(disco.dispatchFindNode(it, randomKey))
      getRPCBatch = toQuery.mapIt(disco.dispatchGetVal(it, it.toKey()))
      completedFindRPCBatch = await findRPCBatch.collectCompleted(disco.config.timeout)
      completedGetRPCBatch = await getRPCBatch.collectCompleted(disco.config.timeout)

    for (fut, peerId) in zip(findRPCBatch, toQuery):
      if fut.completed():
        state.responded.incl(peerId)

    for msg in completedFindRPCBatch:
      msg.withValue(reply):
        let newPeerInfos = state.updateShortlist(reply)
        disco.updatePeers(newPeerInfos)

    for msg in completedGetRPCBatch:
      let reply = msg.valueOr:
        continue

      let record = reply.record.valueOr:
        continue

      let buffer = record.value.valueOr:
        continue

      buffers.add(buffers)

  var records: seq[ExtPeerRecord]
  for buffer in buffers:
    let xpr = ExtPeerRecord.decode(buffer).valueOr:
      debug "cannot decode signed peer record", error
      continue

    records.add(xpr)

  return records

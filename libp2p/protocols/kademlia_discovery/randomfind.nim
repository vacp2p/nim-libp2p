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

  var state = LookupState.init(disco, randomKey)
  var buffers: seq[seq[byte]]

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

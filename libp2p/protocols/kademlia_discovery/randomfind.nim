# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[sequtils, sets]
import chronos, chronicles, results
import ../../[peerid, peerinfo, switch, multihash, routing_record]
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

  var buffers: seq[seq[byte]]
  let bufferReply = proc(
      peerID: PeerId, _: Opt[Message], _: var LookupState
  ): Future[void] {.async: (raises: []), gcsafe.} =
    let res = catch:
      await disco.dispatchGetVal(peerID, peerID.toKey())

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

proc filterByServices(
    records: seq[ExtendedPeerRecord], services: HashSet[ServiceInfo]
): seq[ExtendedPeerRecord] =
  records.filterIt(it.services.anyIt(services.contains(it)))

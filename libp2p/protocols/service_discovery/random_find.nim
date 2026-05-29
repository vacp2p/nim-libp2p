# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets, tables]
import chronos, chronicles, results
import ../../[peerid, peerinfo, switch, multihash, routing_record, extended_peer_record]
import ../protocol
import ../kademlia/[types, find, get, protobuf]
import ./[types]

logScope:
  topics = "ext-kad-dht random records"

proc cancelPending(
    futs: seq[Future[Result[Message, string]].Raising([CancelledError])]
) {.async: (raises: []).} =
  var pending: seq[FutureBase]
  for fut in futs:
    if not fut.finished:
      pending.add(fut)
  if pending.len > 0:
    await noCancel allFutures(pending.mapIt(it.cancelAndWait()))

proc randomRecords(
    disco: ServiceDiscovery
): Future[seq[ExtendedPeerRecord]] {.async: (raises: [CancelledError]).} =
  ## Return all peer records on the path towards a random target ID.

  let randomPeerId = PeerId.random(disco.rng).valueOr:
    debug "cannot generate random peer id", error
    return @[]

  let randomKey = randomPeerId.toKey()

  let state = LookupState.init(disco, randomKey)
  var queried: HashSet[PeerId]
  var getValFuts: seq[Future[Result[Message, string]].Raising([CancelledError])]

  try:
    while not closestAvailableStop(state):
      let progressed =
        await disco.lookOnce(state, disco.rtable, findNodeDispatch, noopReply)
      if not progressed:
        break

      # Issue getValue requests as soon as peers respond, so they run in
      # parallel with the next lookup round.
      for peerId, status in state.responded:
        if status == RespondedStatus.Success and peerId notin queried:
          queried.incl(peerId)
          getValFuts.add(disco.dispatchGetVal(peerId, peerId.toKey()))
  except CancelledError as e:
    await cancelPending(getValFuts)
    raise e

  var buffers: seq[seq[byte]]
  for fut in getValFuts:
    let res =
      try:
        await fut
      except CancelledError as e:
        await cancelPending(getValFuts)
        raise e

    let reply = res.valueOr:
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

  records.toSeq()

proc lookupRandom*(
    disco: ServiceDiscovery
): Future[seq[ExtendedPeerRecord]] {.async: (raises: [CancelledError]).} =
  await disco.randomRecords()

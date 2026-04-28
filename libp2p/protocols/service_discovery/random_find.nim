# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets]
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

  let queue = newAsyncQueue[(PeerId, Opt[Message])]()

  let peers = disco.rtable.findClosestPeerIds(randomKey, disco.config.replication)
  for peer in peers:
    let addRes = catch:
      queue.addFirstNoWait((peer, Opt.none(Message)))
    if addRes.isErr:
      error "cannot enqueue peer", error = addRes.error.msg

  let findNodeFut = disco.findNode(randomKey, queue)

  var buffers: seq[seq[byte]]
  while not findNodeFut.finished or not queue.empty():
    let peerId =
      if queue.empty():
        # The queue is temporarily empty while findNodeFut may still enqueue
        # more peers. Use an event to wake up when either a peer is enqueued
        # OR findNodeFut finishes, so we react to whichever comes first.
        let popFirstFut = queue.popFirst()
        let wakeEvent = newAsyncEvent()
        popFirstFut.addCallback(
          proc(_: pointer) {.gcsafe, raises: [].} =
            wakeEvent.fire()
        )
        findNodeFut.addCallback(
          proc(_: pointer) {.gcsafe, raises: [].} =
            wakeEvent.fire()
        )
        try:
          await wakeEvent.wait()
        except CancelledError as e:
          await popFirstFut.cancelAndWait()
          raise e

        if popFirstFut.completed:
          let (peerId, _) = await popFirstFut
          peerId
        else:
          await popFirstFut.cancelAndWait()
          break
      else:
        let (peerId, _) = await queue.popFirst()
        peerId
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

  let findNodeRes = catch:
    await findNodeFut
  if findNodeRes.isErr:
    error "kad find node failed", error = findNodeRes.error.msg

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

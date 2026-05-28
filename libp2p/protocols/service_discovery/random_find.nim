# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets]
import chronos, chronicles, results
import ../../[peerid, peerinfo, switch, multihash, routing_record, extended_peer_record]
import ../../utils/asyncheapqueue
import ../protocol
import ../kademlia/[types, find, get, protobuf, routing_table]
import ./[types]

logScope:
  topics = "ext-kad-dht random records"

proc makeFireCallback(event: AsyncEvent): CallbackFunc =
  proc(_: pointer) {.gcsafe, raises: [].} =
    event.fire()

proc nextPeer(
    queue: AsyncHeapQueue[PeerDistance], findNodeFut: Future[seq[PeerId]]
): Future[Opt[PeerId]] {.async: (raises: [CancelledError]).} =
  ## Pop the closest peer from the heap, blocking until one arrives or
  ## findNodeFut finishes. Returns none when no more peers will come.
  if not queue.empty():
    let entry = await queue.pop()
    return Opt.some(entry.peerId)

  # Heap is temporarily empty while findNodeFut may still push more peers.
  # Wait for whichever comes first.
  let popFut = queue.pop()
  let wakeEvent = newAsyncEvent()
  popFut.addCallback(makeFireCallback(wakeEvent))
  findNodeFut.addCallback(makeFireCallback(wakeEvent))
  try:
    await wakeEvent.wait()
  except CancelledError as e:
    await popFut.cancelAndWait()
    raise e

  if popFut.completed:
    let entry = await popFut
    Opt.some(entry.peerId)
  else:
    await popFut.cancelAndWait()
    Opt.none(PeerId)

proc randomRecords(
    disco: ServiceDiscovery
): Future[seq[ExtendedPeerRecord]] {.async: (raises: [CancelledError]).} =
  ## Return all peer records on the path towards a random target ID.

  let randomPeerId = PeerId.random(disco.rng).valueOr:
    debug "cannot generate random peer id", error
    return @[]

  let randomKey = randomPeerId.toKey()

  let queue = newAsyncHeapQueue[PeerDistance]()

  let peers = disco.rtable.findClosestPeerIds(randomKey, disco.config.replication)
  for peer in peers:
    let distance = xorDistance(peer, randomKey, disco.rtable.config.hasher)
    queue.push(PeerDistance(peerId: peer, distance: distance))

  let findNodeFut = disco.findNode(randomKey, queue)

  var buffers: seq[seq[byte]]
  try:
    while not findNodeFut.finished or not queue.empty():
      let peerId = (await nextPeer(queue, findNodeFut)).valueOr:
        break

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
  except CancelledError as e:
    await findNodeFut.cancelAndWait()
    raise e

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

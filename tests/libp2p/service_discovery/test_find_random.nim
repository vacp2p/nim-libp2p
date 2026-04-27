# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, std/sequtils
import ../../../libp2p/protocols/[kademlia, service_discovery]
import ../../tools/[lifecycle, topology, unittest]
import ./utils

proc hasKey(disco: ServiceDiscovery, key: Key): bool =
  for b in disco.rtable.buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        return true
  return false

suite "Service discovery - FindRandom":
  teardown:
    checkTrackers()

  asyncTest "Simple find random node":
    let discos = setupDiscos(5, ExtEntryValidator(), ExtEntrySelector())
    startAndDeferStop(discos)

    await connectStar(discos)

    let records = await discos[1].lookupRandom()

    check records.len == 4
    let peerIds = discos.mapIt(it.switch.peerInfo.peerId)
    for record in records:
      check record.peerId in peerIds

  asyncTest "lookupRandom completes when findNode finishes without enqueuing peers":
    # Regression test for the empty-queue / in-flight-findNodeFut hang:
    # with an empty routing table, findNode completes immediately without ever
    # enqueuing a peer.  The loop condition `not findNodeFut.finished or not
    # queue.empty()` is true on the first iteration (findNodeFut hasn't run yet),
    # so we enter the queue.empty() branch.  The old code called
    # `await queue.popFirst()` which blocked forever once findNodeFut finished
    # silently; the fix uses `await one(popFirstFut, findNodeFut)` so that
    # findNodeFut completing is sufficient to unblock and exit.
    let discos = setupDiscos(1, ExtEntryValidator(), ExtEntrySelector())
    startAndDeferStop(discos)

    # No peers are connected, so the routing table is empty and findNode returns
    # without adding anything to the queue.  This must complete, not hang.
    check await discos[0].lookupRandom().withTimeout(5.seconds)

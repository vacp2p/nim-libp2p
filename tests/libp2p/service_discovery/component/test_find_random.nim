# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, sequtils
import ../../../../libp2p/protocols/service_discovery
import ../../../tools/[lifecycle, topology, unittest]
import ../utils

suite "Service Discovery Component - Find Random":
  teardown:
    checkTrackers()

  asyncTest "Simple find random node":
    let discos = setupServiceDiscoveryNodes(5)
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
    let discos = setupServiceDiscoveryNodes(1)
    startAndDeferStop(discos)

    # No peers are connected, so the routing table is empty and findNode returns
    # without adding anything to the queue.  This must complete, not hang.
    check await discos[0].lookupRandom().withTimeout(5.seconds)

  asyncTest "lookupRandom can be cancelled while suspended on the queue-empty event":
    # Regression: without the popFirstFut cancel guard, cancelling randomRecords
    # while it awaits wakeEvent.wait() leaves popFirstFut attached to the queue
    # as an orphaned getter. That getter silently consumes the next peer enqueued
    # by the still-running findNodeFut, leaking transport resources that are
    # caught by teardown checkTrackers.
    let discos = setupServiceDiscoveryNodes(3)
    startAndDeferStop(discos)
    await connectStar(discos)

    let fut = discos[0].lookupRandom()
    await sleepAsync(1.millis)
    await fut.cancelAndWait()

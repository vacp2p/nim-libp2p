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
    # With an empty routing table, findNode completes immediately without ever
    # pushing a peer onto the heap. The drain loop then sees an empty heap and
    # exits, so lookupRandom must complete rather than hang.
    let discos = setupServiceDiscoveryNodes(1)
    startAndDeferStop(discos)

    # No peers are connected, so the routing table is empty and findNode returns
    # without adding anything to the queue.  This must complete, not hang.
    check await discos[0].lookupRandom().withTimeout(5.seconds)

  asyncTest "lookupRandom can be cancelled while the lookup is in flight":
    # Cancelling lookupRandom while it is awaiting findNode must propagate the
    # cancellation cleanly without leaking transport resources, which teardown's
    # checkTrackers verifies.
    let discos = setupServiceDiscoveryNodes(3)
    startAndDeferStop(discos)
    await connectStar(discos)

    let fut = discos[0].lookupRandom()
    await sleepAsync(1.millis)
    await fut.cancelAndWait()

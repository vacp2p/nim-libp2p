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

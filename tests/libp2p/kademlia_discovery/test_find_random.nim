# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, std/sequtils
import ../../../libp2p/protocols/[kademlia, kad_disco]
import ../../tools/[lifecycle, topology, unittest]
import ./utils

proc hasKey(kad: KademliaDiscovery, key: Key): bool =
  for b in kad.rtable.buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        return true
  return false

suite "Kademlia discovery - FindRandom":
  teardown:
    checkTrackers()

  asyncTest "Simple find random node":
    let kads = setupKads(5, ExtEntryValidator(), ExtEntrySelector())
    startNodesAndDeferStop(kads)

    connectNodesStar(kads, connectNodes)

    let records = await kads[1].randomRecords()

    check records.len == 4
    let peerIds = kads.mapIt(it.switch.peerInfo.peerId)
    for record in records:
      check record.peerId in peerIds

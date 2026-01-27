# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronicles, chronos, std/[sequtils, enumerate]
import ../../../libp2p/[switch, builders]
import ../../../libp2p/protocols/[kademlia, kad_disco]
import ../../tools/[unittest]
import ./utils.nim

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

suite "Kademlia discovery - FindRandom":
  teardown:
    checkTrackers()

  asyncTest "Simple find random node":
    let swarmSize = 5
    var switches: seq[Switch]
    var kads: seq[KademliaDiscovery]
    for i in 0 ..< swarmSize:
      var (switch, kad) =
        if i == 0:
          setupKadSwitch(ExtEntryValidator(), ExtEntrySelector())
        else:
          setupKadSwitch(
            ExtEntryValidator(),
            ExtEntrySelector(),
            @[(switches[0].peerInfo.peerId, switches[0].peerInfo.addrs)],
          )
      switches.add(switch)
      kads.add(kad)

    # Bootstrapping needs to be done sequentially
    for i in 1 ..< swarmSize:
      await kads[i].bootstrap()

    var entries = @[kads[0].rtable.selfId]

    #  All the nodes that bootstropped off kad[0] have exactly 1 of each previous nodes, + kads[0], in their buckets
    for i, kad in enumerate(kads[1 ..^ 1]):
      for id in entries:
        check kad.hasKey(id)
      entries.add(kad.rtable.selfId)

    let records = await kads[1].randomRecords()

    check records.len == 4
    for record in records:
      check switches.anyIt(it.peerInfo.peerId == record.peerId)

    await switches.mapIt(it.stop()).allFutures()

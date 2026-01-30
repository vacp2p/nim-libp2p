# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, std/sequtils
import ../../../libp2p/protocols/[kademlia, kad_disco]
import ../../tools/[unittest]
import ../capability_discovery/utils

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

suite "Kademlia discovery - FindRandom":
  teardown:
    checkTrackers()

  asyncTest "Simple find random node":
    let kads = setupKads(5, ExtEntryValidator(), ExtEntrySelector())
    startAndDeferStop(kads)

    await connectStar(kads)

    let records = await kads[1].randomRecords()

    check records.len == 4
    let peerIds = kads.mapIt(it.switch.peerInfo.peerId)
    for record in records:
      check record.peerId in peerIds

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./utils.nim

suite "KadDHT Ping":
  teardown:
    checkTrackers()

  asyncTest "Simple ping":
    let kads = await setupKadSwitches(2)
    defer:
      await stopNodes(kads)

    connectNodes(kads[0], kads[1])

    check:
      await kads[0].ping(kads[1].switch.peerInfo.peerId, kads[1].switch.peerInfo.addrs)
      await kads[1].ping(kads[0].switch.peerInfo.peerId, kads[0].switch.peerInfo.addrs)

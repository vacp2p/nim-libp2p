# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, chronicles
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[unittest]
import ./utils.nim

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

suite "KadDHT Ping":
  teardown:
    checkTrackers()

  asyncTest "Simple ping":
    var (switch1, kad1) = await setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = await setupKadSwitch(
      PermissiveValidator(),
      CandSelector(),
      @[(switch1.peerInfo.peerId, switch1.peerInfo.addrs)],
    )

    defer:
      await allFutures(switch1.stop(), switch2.stop())

    check:
      await kad1.ping(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
      await kad2.ping(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos
import ../../libp2p/[protocols/kademlia, switch, builders]
import ../tools/[unittest]
import ./utils.nim

suite "KadDHT - Ping":
  teardown:
    checkTrackers()

  asyncTest "Simple ping":
    var (switch1, kad1) = setupKadSwitch(PermissiveValidator(), CandSelector())
    var (switch2, kad2) = setupKadSwitch(PermissiveValidator(), CandSelector())

    defer:
      await allFutures(switch1.stop(), switch2.stop())

    await kad2.bootstrap(@[switch1.peerInfo])

    check:
      await kad1.ping(switch2.peerInfo.peerId, switch2.peerInfo.addrs)
      await kad2.ping(switch1.peerInfo.peerId, switch1.peerInfo.addrs)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, sequtils, results
import ../../libp2p/[builders, switch]
import ../tools/[unittest, futures, crypto]

suite "Dialer":
  teardown:
    checkTrackers()

  asyncTest "Connect forces a new connection":
    let
      src = newStandardSwitch(maxConnsPerPeer = 2, rng = rng())
      dst = newStandardSwitch(maxConnsPerPeer = 2, rng = rng())

    await dst.start()

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    check src.connManager.connCount(dst.peerInfo.peerId) == 1

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs)
    check src.connManager.connCount(dst.peerInfo.peerId) == 1

    await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs, true, false)
    check src.connManager.connCount(dst.peerInfo.peerId) == 2

    await allFutures(src.stop(), dst.stop())

  asyncTest "Max connections reached":
    var switches: seq[Switch]

    let dst =
      newStandardSwitch(connectionLimits = Opt.some(ConnectionLimits.maxTotal(2)), rng = rng())
    await dst.start()
    switches.add(dst)

    for i in 1 ..< 3:
      let src = newStandardSwitch(rng = rng())
      switches.add(src)
      await src.start()
      await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs, true, false)

    let src = newStandardSwitch(rng = rng())
    switches.add(src)
    await src.start()
    check not await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs).withTimeout(
      1000.millis
    )

    await allFuturesRaising(switches.mapIt(it.stop()))

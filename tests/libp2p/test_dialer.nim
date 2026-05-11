# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, sequtils, results
import ../../libp2p/[builders, switch]
import ../tools/[unittest, futures, switch_builder]

suite "Dialer":
  teardown:
    checkTrackers()

  asyncTest "Connect forces a new connection":
    let
      src = makeStandardSwitchBuilder().withMaxConnsPerPeer(2).build()
      dst = makeStandardSwitchBuilder().withMaxConnsPerPeer(2).build()

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

    let dst = makeStandardSwitchBuilder()
      .withConnectionLimits(ConnectionLimits.maxTotal(2))
      .build()
    await dst.start()
    switches.add(dst)

    for i in 1 ..< 3:
      let src = makeStandardSwitch()
      switches.add(src)
      await src.start()
      await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs, true, false)

    let src = makeStandardSwitch()
    switches.add(src)
    await src.start()
    check not await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs).withTimeout(
      1000.millis
    )

    await allFuturesRaising(switches.mapIt(it.stop()))

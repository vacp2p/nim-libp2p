# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/options
import chronos
import sequtils
import unittest2
import ../libp2p/[builders, switch]
import ./helpers

suite "Dialer":
  teardown:
    checkTrackers()

  asyncTest "Connect forces a new connection":
    let
      src = newStandardSwitch()
      dst = newStandardSwitch()

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

    let dst = newStandardSwitch(maxConnections = 2)
    await dst.start()
    switches.add(dst)

    for i in 1 ..< 3:
      let src = newStandardSwitch()
      switches.add(src)
      await src.start()
      await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs, true, false)

    let src = newStandardSwitch()
    switches.add(src)
    await src.start()
    check not await src.connect(dst.peerInfo.peerId, dst.peerInfo.addrs).withTimeout(
      1000.millis
    )

    await allFuturesThrowing(allFutures(switches.mapIt(it.stop())))

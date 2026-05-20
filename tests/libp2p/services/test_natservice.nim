# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/net
import chronos
import ../../../libp2p/[builders, switch, multiaddress, multicodec]
import ../../tools/[unittest, crypto]

proc makeSwitch(
    config: NATConfig, listenAddrs: seq[MultiAddress]
): Switch {.raises: [LPError].} =
  SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(listenAddrs, false)
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withNAT(config)
    .build()

suite "NATService":
  teardown:
    checkTrackers()

  asyncTest "natModeExplicitIp announces the explicit IP with bound ports":
    let
      explicitIp = parseIpAddress("203.0.113.7")
      cfg = NATConfig(mode: natModeExplicitIp, explicitIp: explicitIp)
      switch = makeSwitch(cfg, @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.listenAddrs.len == 1
    let boundPort = switch.peerInfo.listenAddrs[0][multiCodec("tcp")].get
    let expected = MultiAddress.init("/ip4/" & $explicitIp & $boundPort).tryGet()

    check switch.peerInfo.addrs == @[expected]

  asyncTest "natModeAuto is a no-op on announced addresses":
    let
      cfg = NATConfig(mode: natModeAuto)
      switch = makeSwitch(cfg, @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.announcedAddrs.len == 0
    # addrs falls back to mapper-chain output (which here is just listenAddrs).
    check switch.peerInfo.addrs == switch.peerInfo.listenAddrs

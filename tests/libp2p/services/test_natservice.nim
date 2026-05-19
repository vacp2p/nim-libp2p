# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/net
import chronos
import ../../../libp2p/[builders, switch, services/natservice, multiaddress, multicodec]
import ../../tools/[unittest, crypto]

proc createSwitch(
    natService: Service, listenAddrs: seq[MultiAddress]
): Switch {.raises: [LPError].} =
  let switch = SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(listenAddrs, false)
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .build()
  switch.add(natService)
  switch

suite "NATService":
  teardown:
    checkTrackers()

  asyncTest "natModeExplicitIp populates announcedAddrs from bound listen ports":
    let
      explicitIp = parseIpAddress("203.0.113.7")
      cfg = NATConfig.init(natModeExplicitIp, Opt.some(explicitIp))
      natService = NATService.new(cfg)
      switch =
        createSwitch(natService, @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.listenAddrs.len == 1
    let boundPort = switch.peerInfo.listenAddrs[0][multiCodec("tcp")].get
    let expected = MultiAddress.init("/ip4/203.0.113.7" & $boundPort).tryGet()

    check switch.peerInfo.announcedAddrs == @[expected]
    check switch.peerInfo.addrs == @[expected]

  asyncTest "natModeAuto is a no-op on announcedAddrs":
    let
      cfg = NATConfig.init(natModeAuto)
      natService = NATService.new(cfg)
      switch =
        createSwitch(natService, @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.announcedAddrs.len == 0
    # addrs falls back to mapper-chain output (which here is just listenAddrs).
    check switch.peerInfo.addrs == switch.peerInfo.listenAddrs

  asyncTest "stop clears announcedAddrs and reverts to mapper chain":
    let
      explicitIp = parseIpAddress("203.0.113.7")
      cfg = NATConfig.init(natModeExplicitIp, Opt.some(explicitIp))
      natService = NATService.new(cfg)
      switch =
        createSwitch(natService, @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])

    await switch.start()
    check switch.peerInfo.announcedAddrs.len == 1
    await switch.stop()
    check switch.peerInfo.announcedAddrs.len == 0

  asyncTest "withNAT builder wires the service through Switch":
    let
      explicitIp = parseIpAddress("203.0.113.7")
      cfg = NATConfig.init(natModeExplicitIp, Opt.some(explicitIp))
      switch = SwitchBuilder
        .new()
        .withRng(rng())
        .withAddresses(@[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()], false)
        .withTcpTransport()
        .withMplex()
        .withNoise()
        .withNAT(cfg)
        .build()

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.announcedAddrs.len == 1
    let announced = switch.peerInfo.announcedAddrs[0]
    check IP4.matchPartial(announced)
    check switch.peerInfo.addrs == @[announced]

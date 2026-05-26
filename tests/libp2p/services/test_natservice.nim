# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/[net, sequtils, strutils]
import chronos, results
import ../../../libp2p/[builders, switch, multiaddress, multicodec]
import ../../../libp2p/services/natservice
import ../../tools/[unittest, crypto]

proc makeSwitch(
    config: NATConfig, listenAddrs: seq[MultiAddress], mapper: NATPortMapper = nil
): Switch {.raises: [LPError].} =
  ## Tests pass ``mapper`` to inject a fake in place of the production
  ## miniupnpc / libnatpmp backend.
  SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(listenAddrs, false)
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withNAT(config, mapper)
    .build()

# ---------------------------------------------------------------------------
# FakeNATPortMapper — records all calls and lets tests script the responses.
# Used in place of the real miniupnpc / libnatpmp backend so tests don't touch
# the network or require an IGD on the host running CI.
# ---------------------------------------------------------------------------
type
  FakeCallKind = enum
    fckDiscover
    fckAdd
    fckDelete
    fckClose

  FakeCall = object
    kind: FakeCallKind
    internalPort: Port
    externalPort: Port
    protocol: NATProtocol

  FakeNATPortMapper = ref object of NATPortMapper
    externalIp: IpAddress
    mappedExternalPort: Port
      # what addMapping returns regardless of internal port; fixed (not derived
      # from internalPort) so an OS-assigned ephemeral listen port can't push
      # the mapped value past uint16 and trip multiaddress encoding
    discoverFails: int # how many discover calls should err before succeeding
    discoverCount: int
    addFails: int # how many addMapping calls should err before succeeding
    addCount: int
    calls: seq[FakeCall]

method discoverExternalIp(
    self: FakeNATPortMapper
): Result[IpAddress, string] {.gcsafe.} =
  inc self.discoverCount
  self.calls.add(FakeCall(kind: fckDiscover))
  if self.discoverFails > 0:
    dec self.discoverFails
    return err("fake: discovery failed")
  ok(self.externalIp)

method addMapping(
    self: FakeNATPortMapper,
    internalPort: Port,
    protocol: NATProtocol,
    leaseDuration: Duration,
    description: string,
): Result[Port, string] {.gcsafe.} =
  inc self.addCount
  self.calls.add(FakeCall(kind: fckAdd, internalPort: internalPort, protocol: protocol))
  if self.addFails > 0:
    dec self.addFails
    return err("fake: add failed")
  ok(self.mappedExternalPort)

method deleteMapping(
    self: FakeNATPortMapper,
    externalPort: Port,
    internalPort: Port,
    protocol: NATProtocol,
): Result[void, string] {.gcsafe.} =
  self.calls.add(
    FakeCall(
      kind: fckDelete,
      internalPort: internalPort,
      externalPort: externalPort,
      protocol: protocol,
    )
  )
  ok()

method close(self: FakeNATPortMapper) {.gcsafe.} =
  self.calls.add(FakeCall(kind: fckClose))

suite "NATService":
  teardown:
    checkTrackers()

  test "explicitIpMapped preserves port and suffix; drops mismatching family":
    proc ma(s: string): MultiAddress =
      MultiAddress.init(s).get()

    let
      ip4 = parseIpAddress("203.0.113.7")
      ip6 = parseIpAddress("2001:db8::1")
      mixed = @[
        ma("/ip4/127.0.0.1/tcp/1234"),
        ma("/ip4/127.0.0.1/tcp/80/ws"),
        ma("/ip4/127.0.0.1/tcp/80/tls/ws"),
        ma("/ip4/127.0.0.1/udp/9000/quic-v1"),
        ma("/ip6/::1/tcp/1234"),
        ma("/unix/tmp/sock"),
      ]
    check:
      explicitIpMapped(mixed, ip4) ==
        @[
          ma("/ip4/203.0.113.7/tcp/1234"),
          ma("/ip4/203.0.113.7/tcp/80/ws"),
          ma("/ip4/203.0.113.7/tcp/80/tls/ws"),
          ma("/ip4/203.0.113.7/udp/9000/quic-v1"),
        ]
      explicitIpMapped(mixed, ip6) == @[ma("/ip6/2001:db8::1/tcp/1234")]
      explicitIpMapped(@[ma("/unix/tmp/sock")], ip4).len == 0

  test "explicitIpMapped dedupes addresses sharing port across interfaces":
    proc ma(s: string): MultiAddress =
      MultiAddress.init(s).get()

    let
      ip4 = parseIpAddress("203.0.113.7")
      resolved = @[ma("/ip4/192.168.1.10/tcp/50000"), ma("/ip4/10.0.0.5/tcp/50000")]
    check explicitIpMapped(resolved, ip4) == @[ma("/ip4/203.0.113.7/tcp/50000")]

  asyncTest "ExplicitIp announces the explicit IP with bound ports":
    let
      explicitIp = parseIpAddress("203.0.113.7")
      cfg = NATConfig.new(explicitIp)
      switch = makeSwitch(cfg, @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.listenAddrs.len == 1
    let boundPort = switch.peerInfo.listenAddrs[0][multiCodec("tcp")].get
    let expected = MultiAddress.init("/ip4/" & $explicitIp & $boundPort).tryGet()

    check switch.peerInfo.addrs == @[expected]

  asyncTest "Auto is a no-op on announced addresses":
    let
      cfg = NATConfig.new(Auto)
      switch = makeSwitch(cfg, @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()])

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.announcedAddrs.len == 0
    # addrs falls back to mapper-chain output (which here is just listenAddrs).
    check switch.peerInfo.addrs == switch.peerInfo.listenAddrs

  test "gatewayMapped rewrites both IP and port; preserves transport suffix":
    proc ma(s: string): MultiAddress =
      MultiAddress.init(s).get()

    let
      extIp = parseIpAddress("203.0.113.7")
      mappings = @[
        PortMapping(
          internalPort: Port(4001), externalPort: Port(50001), protocol: NATProtoTcp
        ),
        PortMapping(
          internalPort: Port(9000), externalPort: Port(59000), protocol: NATProtoUdp
        ),
      ]
      input = @[
        ma("/ip4/192.168.1.10/tcp/4001"),
        ma("/ip4/192.168.1.10/tcp/4001/ws"),
        ma("/ip4/192.168.1.10/udp/9000/quic-v1"),
        ma("/ip4/192.168.1.10/tcp/7777"), # no matching mapping -> dropped
        ma("/unix/tmp/sock"), # no ip -> dropped
      ]
    check gatewayMapped(input, extIp, mappings) ==
      @[
        ma("/ip4/203.0.113.7/tcp/50001"),
        ma("/ip4/203.0.113.7/tcp/50001/ws"),
        ma("/ip4/203.0.113.7/udp/59000/quic-v1"),
      ]

  test "gatewayMapped drops listen addrs whose IP family disagrees with ext IP":
    proc ma(s: string): MultiAddress =
      MultiAddress.init(s).get()

    let
      extIp = parseIpAddress("203.0.113.7")
      mappings = @[
        PortMapping(
          internalPort: Port(4001), externalPort: Port(50001), protocol: NATProtoTcp
        )
      ]
      input = @[ma("/ip6/2001:db8::1/tcp/4001"), ma("/ip4/192.168.1.10/tcp/4001")]
    check gatewayMapped(input, extIp, mappings) == @[ma("/ip4/203.0.113.7/tcp/50001")]

  asyncTest "Upnp acquires mapping at start, announces ext IP, deletes on stop":
    let mapper = FakeNATPortMapper(
      externalIp: parseIpAddress("203.0.113.7"), mappedExternalPort: Port(50001)
    )
    let
      # leaseDuration is long enough that the refresh tick (lease / 2) won't
      # fire during the test.
      cfg = NATConfig.new(Upnp, description = "test", leaseDuration = 1.hours)
      switch =
        makeSwitch(cfg, @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()], mapper)

    await switch.start()

    # The mapper sees one discover + one add at startup.
    check mapper.discoverCount == 1
    check mapper.addCount == 1
    check mapper.calls.anyIt(it.kind == fckAdd and it.protocol == NATProtoTcp)

    # peerInfo.addrs surfaces the (extIp, mappedPort) pair from the fake mapper.
    let expected = MultiAddress.init("/ip4/203.0.113.7/tcp/50001").tryGet()
    check switch.peerInfo.addrs == @[expected]

    await switch.stop()

    # On stop the fake sees a delete for each mapping it handed out plus close().
    check mapper.calls.anyIt(it.kind == fckDelete)
    check mapper.calls.anyIt(it.kind == fckClose)

  asyncTest "NatPmp uses the supplied mapper and announces the NAT-PMP ext IP":
    let mapper = FakeNATPortMapper(
      externalIp: parseIpAddress("198.51.100.42"), mappedExternalPort: Port(50042)
    )
    let
      cfg = NATConfig.new(NatPmp, leaseDuration = 1.hours)
      switch =
        makeSwitch(cfg, @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()], mapper)

    await switch.start()
    defer:
      await switch.stop()

    check mapper.discoverCount == 1
    check switch.peerInfo.addrs.len == 1
    check ($switch.peerInfo.addrs[0]).find("/ip4/198.51.100.42/") >= 0

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/net
import chronos, results
import ../../../libp2p/[builders, switch, multiaddress, multicodec, peerinfo, wire]
import ../../../libp2p/services/natservice
import ../../../libp2p/services/nat/portmapper
import ../../tools/[unittest, crypto]

proc makeSwitch(
    config: NATConfig,
    listenAddrs: seq[MultiAddress],
    portMapperFactory: PortMapperFactory = nil,
): Switch {.raises: [LPError].} =
  SwitchBuilder
    .new()
    .withRng(rng())
    .withAddresses(listenAddrs, false)
    .withTcpTransport()
    .withMplex()
    .withNoise()
    .withNAT(config, portMapperFactory)
    .build()

# ---------------------------------------------------------------------------
# Mock port mapper
# ---------------------------------------------------------------------------

type MockPortMapper = ref object of PortMapper
  externalIp: IpAddress
  discoverResult: Result[IpAddress, string]
  mapResult: Result[Port, string]
  unmapResult: Result[void, string]
  discoverCalls: int
  mapCalls: seq[tuple[internal, external: Port, proto: MapProto, lease: uint32]]
  unmapCalls: seq[tuple[external: Port, proto: MapProto]]
  closed: bool
  mapEvent: AsyncEvent

method discover*(
    self: MockPortMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  inc self.discoverCalls
  self.discoverResult

method map*(
    self: MockPortMapper,
    internalPort: Port,
    externalPort: Port,
    proto: MapProto,
    lease: uint32,
): Future[Result[Port, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  self.mapCalls.add((internalPort, externalPort, proto, lease))
  if self.mapEvent != nil:
    self.mapEvent.fire()
  if self.mapResult.isErr:
    self.mapResult
  else:
    Result[Port, string].ok(externalPort)

method unmap*(
    self: MockPortMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  self.unmapCalls.add((externalPort, proto))
  self.unmapResult

method close*(self: MockPortMapper) {.gcsafe, raises: [].} =
  self.closed = true

proc newMockOk(externalIp: IpAddress): MockPortMapper =
  MockPortMapper(
    externalIp: externalIp,
    discoverResult: Result[IpAddress, string].ok(externalIp),
    mapResult: Result[Port, string].ok(Port(0)), # actual port set per call
    unmapResult: Result[void, string].ok(),
  )

proc mockFactoryFail(): PortMapperFactory =
  let mapper = MockPortMapper(
    discoverResult: Result[IpAddress, string].err("mock no IGD"),
    mapResult: Result[Port, string].err("not discovered"),
    unmapResult: Result[void, string].ok(),
  )
  return proc(mode: NATMode): PortMapper {.gcsafe, raises: [].} =
    mapper

proc findNatService(switch: Switch): NATService =
  for s in switch.services:
    if s of NATService:
      return NATService(s)
  raiseAssert "NATService not found in switch.services"

proc loopbackAddr(): MultiAddress =
  MultiAddress.init("/ip4/127.0.0.1/tcp/0").get()

proc privateAddr(port: int = 9000): MultiAddress =
  MultiAddress.init("/ip4/192.168.1.5/tcp/" & $port).get()

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

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

  asyncTest "natModeExplicitIp announces the explicit IP with bound ports":
    let
      explicitIp = parseIpAddress("203.0.113.7")
      cfg = NATConfig(mode: natModeExplicitIp, explicitIp: explicitIp)
      switch = makeSwitch(cfg, @[loopbackAddr()])

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
      switch = makeSwitch(cfg, @[loopbackAddr()])

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.announcedAddrs.len == 0
    # addrs falls back to mapper-chain output (which here is just listenAddrs).
    check switch.peerInfo.addrs == switch.peerInfo.listenAddrs

  asyncTest "natModeUpnp announces external IP after successful mapping":
    let
      externalIp = parseIpAddress("203.0.113.42")
      mapper = newMockOk(externalIp)
      factory = proc(mode: NATMode): PortMapper {.gcsafe, raises: [].} =
        mapper
      cfg = upnpConfig(refreshInterval = 1.hours)
      switch = makeSwitch(cfg, @[loopbackAddr()], factory)
      svc = findNatService(switch)

    await switch.start()
    defer:
      await switch.stop()

    # Loopback isn't "private" — the mapper sits idle until we feed it a
    # private listen address. Drive setupMappings directly with one.
    let announced = await svc.setupMappings(@[privateAddr(9000)])
    check announced.len == 1
    check svc.externalIp.isSome
    check svc.externalIp.get() == externalIp
    let annTa = initTAddress(announced[0]).tryGet()
    check annTa.address_v4 == externalIp.address_v4
    check annTa.port == Port(9000)

  asyncTest "natModeUpnp discovery failure leaves announced empty":
    let
      cfg = upnpConfig(refreshInterval = 1.hours)
      switch = makeSwitch(cfg, @[loopbackAddr()], mockFactoryFail())
      svc = findNatService(switch)

    await switch.start()
    defer:
      await switch.stop()

    let announced = await svc.setupMappings(@[privateAddr(9000)])
    check announced.len == 0
    check svc.externalIp.isNone

  asyncTest "natModeUpnp refresh loop reissues map calls":
    let
      externalIp = parseIpAddress("203.0.113.55")
      mapper = newMockOk(externalIp)
    mapper.mapEvent = newAsyncEvent()

    let
      factory = proc(mode: NATMode): PortMapper {.gcsafe, raises: [].} =
        mapper
      cfg = upnpConfig(refreshInterval = 50.milliseconds)
      switch = makeSwitch(cfg, @[loopbackAddr()], factory)

    await switch.start()
    defer:
      await switch.stop()

    # Override the bound listenAddrs with a private one so the addressMapper
    # actually runs the mapper. The refresh loop calls peerInfo.update(), which
    # re-invokes the addressMapper.
    switch.peerInfo.listenAddrs = @[privateAddr(9000)]
    await switch.peerInfo.update()
    let firstCalls = mapper.mapCalls.len
    check firstCalls >= 1

    mapper.mapEvent.clear()
    await mapper.mapEvent.wait()
    check mapper.mapCalls.len > firstCalls

  asyncTest "natModeUpnp stop unmaps all created mappings":
    let
      externalIp = parseIpAddress("203.0.113.7")
      mapper = newMockOk(externalIp)
      factory = proc(mode: NATMode): PortMapper {.gcsafe, raises: [].} =
        mapper
      cfg = upnpConfig(refreshInterval = 1.hours)
      switch = makeSwitch(cfg, @[loopbackAddr()], factory)
      svc = findNatService(switch)

    await switch.start()

    discard await svc.setupMappings(@[privateAddr(9000)])
    let mapsBefore = mapper.mapCalls.len

    await switch.stop()

    check mapsBefore >= 1
    check mapper.unmapCalls.len == mapsBefore
    check mapper.closed

  asyncTest "natModeNatPmp announces external IP after successful mapping":
    let
      externalIp = parseIpAddress("203.0.113.99")
      mapper = newMockOk(externalIp)
      factory = proc(mode: NATMode): PortMapper {.gcsafe, raises: [].} =
        mapper
      cfg = natPmpConfig(refreshInterval = 1.hours)
      switch = makeSwitch(cfg, @[loopbackAddr()], factory)
      svc = findNatService(switch)

    await switch.start()
    defer:
      await switch.stop()

    let announced = await svc.setupMappings(@[privateAddr(9000)])
    check announced.len == 1
    check svc.externalIp.isSome
    check svc.externalIp.get() == externalIp

  asyncTest "non-private listen addresses are skipped":
    let
      externalIp = parseIpAddress("203.0.113.1")
      mapper = newMockOk(externalIp)
      factory = proc(mode: NATMode): PortMapper {.gcsafe, raises: [].} =
        mapper
      cfg = upnpConfig(refreshInterval = 1.hours)
      switch = makeSwitch(cfg, @[loopbackAddr()], factory)
      svc = findNatService(switch)

    await switch.start()
    defer:
      await switch.stop()

    # Public + loopback addresses only → discover never runs, no mappings made.
    let announced = await svc.setupMappings(
      @[
        MultiAddress.init("/ip4/8.8.8.8/tcp/9000").tryGet(),
        MultiAddress.init("/ip4/127.0.0.1/tcp/9001").tryGet(),
      ]
    )

    check mapper.discoverCalls == 0
    check mapper.mapCalls.len == 0
    check announced.len == 0

  asyncTest "user-set announcedAddrs are not overwritten":
    let
      externalIp = parseIpAddress("203.0.113.111")
      userAddr = MultiAddress.init("/ip4/198.51.100.7/tcp/4242").tryGet()
      mapper = newMockOk(externalIp)
      factory = proc(mode: NATMode): PortMapper {.gcsafe, raises: [].} =
        mapper
      cfg = upnpConfig(refreshInterval = 1.hours)
      switch = makeSwitch(cfg, @[loopbackAddr()], factory)

    switch.peerInfo.announcedAddrs = @[userAddr]

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.announcedAddrs == @[userAddr]
    # expandAddrs uses announcedAddrs directly when set, bypassing the
    # addressMapper chain — so the mapper should never have been consulted.
    check mapper.discoverCalls == 0

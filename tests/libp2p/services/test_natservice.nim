# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/net
import chronos, results
import ../../../libp2p/[builders, switch, multiaddress, multicodec]
import ../../../libp2p/services/natservice
import ../../../libp2p/services/nat/portmapper
import ../../tools/[unittest, crypto, multiaddress]

type
  MockCallKind = enum
    mckDiscover
    mckMap
    mckUnmap
    mckClose

  MockCall = object
    kind: MockCallKind
    internalPort: Port
    externalPort: Port
    proto: MapProto
    lease: uint32

  MockPortMapper = ref object of PortMapper
    extIp: IpAddress
    discoverErr: Opt[string]
    extPortQueue: seq[Port]
    extPortIdx: int
    mapErr: Opt[string]
    calls: seq[MockCall]

proc newMock(
    extIp = parseIpAddress("203.0.113.7"),
    extPorts: seq[Port] = @[],
    discoverErr = Opt.none(string),
    mapErr = Opt.none(string),
): MockPortMapper =
  MockPortMapper(
    extIp: extIp, discoverErr: discoverErr, mapErr: mapErr, extPortQueue: extPorts
  )

method discover*(
    self: MockPortMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  self.calls.add(MockCall(kind: mckDiscover))
  if self.discoverErr.isSome:
    return err(self.discoverErr.get())
  ok(self.extIp)

method map*(
    self: MockPortMapper,
    internalPort: Port,
    externalPort: Port,
    proto: MapProto,
    lease: uint32,
): Future[Result[Port, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let assigned =
    if self.extPortIdx < self.extPortQueue.len:
      let p = self.extPortQueue[self.extPortIdx]
      self.extPortIdx.inc
      p
    else:
      externalPort
  self.calls.add(
    MockCall(
      kind: mckMap,
      internalPort: internalPort,
      externalPort: assigned,
      proto: proto,
      lease: lease,
    )
  )
  if self.mapErr.isSome:
    return err(self.mapErr.get())
  ok(assigned)

method unmap*(
    self: MockPortMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  self.calls.add(MockCall(kind: mckUnmap, externalPort: externalPort, proto: proto))
  ok()

method close*(self: MockPortMapper) {.async: (raises: []), gcsafe.} =
  self.calls.add(MockCall(kind: mckClose))

proc countCalls(m: MockPortMapper, kind: MockCallKind): int =
  for c in m.calls:
    if c.kind == kind:
      result.inc

proc unmappedPorts(m: MockPortMapper): seq[Port] =
  for c in m.calls:
    if c.kind == mckUnmap:
      result.add(c.externalPort)

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

suite "NATService":
  teardown:
    checkTrackers()

  test "explicitIpMapped preserves port and suffix; drops mismatching family":
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
      cfg = NATConfig(mode: ExplicitIp, explicitIp: explicitIp)
      switch = makeSwitch(cfg, @[TcpAutoAddress])

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.listenAddrs.len == 1
    let boundPort = switch.peerInfo.listenAddrs[0][multiCodec("tcp")].get
    let expected = MultiAddress.init("/ip4/" & $explicitIp & $boundPort).tryGet()

    check switch.peerInfo.addrs == @[expected]

  asyncTest "Auto is a no-op on announced addresses":
    let
      cfg = NATConfig(mode: Auto)
      switch = makeSwitch(cfg, @[TcpAutoAddress])

    await switch.start()
    defer:
      await switch.stop()

    check switch.peerInfo.announcedAddrs.len == 0
    # addrs falls back to mapper-chain output (which here is just listenAddrs).
    check switch.peerInfo.addrs == switch.peerInfo.listenAddrs

  asyncTest "Upnp maps private listen addrs to extIp/extPort":
    let mock = newMock()
    let factory: PortMapperFactory = proc(
        mode: NATMode
    ): Opt[PortMapper] {.gcsafe, raises: [].} =
      Opt.some(PortMapper(mock))

    let switch = makeSwitch(upnpConfig(), @[TcpAutoAddress], factory)
    await switch.start()
    defer:
      await switch.stop()

    # Start ran addressMapper against loopback listenAddrs which findMappable
    # filters out, so no map/discover yet.
    check mock.calls.len == 0
    check switch.peerInfo.addressMappers.len == 1

    let announced =
      await switch.peerInfo.addressMappers[0](@[ma("/ip4/192.168.1.10/tcp/4242")])
    check announced == @[ma("/ip4/203.0.113.7/tcp/4242")]
    check mock.countCalls(mckDiscover) == 1
    check mock.countCalls(mckMap) == 1

  asyncTest "Upnp unmaps stale extPort when IGD reassigns on refresh":
    let mock = newMock(extPorts = @[Port(9000), Port(9001)])
    let factory: PortMapperFactory = proc(
        mode: NATMode
    ): Opt[PortMapper] {.gcsafe, raises: [].} =
      Opt.some(PortMapper(mock))

    let switch = makeSwitch(upnpConfig(), @[TcpAutoAddress], factory)
    await switch.start()
    defer:
      await switch.stop()

    let priv = @[ma("/ip4/192.168.1.10/tcp/4242")]
    let first = await switch.peerInfo.addressMappers[0](priv)
    let second = await switch.peerInfo.addressMappers[0](priv)

    check first == @[ma("/ip4/203.0.113.7/tcp/9000")]
    check second == @[ma("/ip4/203.0.113.7/tcp/9001")]
    # extPort changed between refreshes — old mapping (9000) must be unmapped.
    check Port(9000) in mock.unmappedPorts()
    check Port(9001) notin mock.unmappedPorts()

  asyncTest "Upnp unmaps everything when private listenAddrs disappear":
    let mock = newMock(extPorts = @[Port(7000)])
    let factory: PortMapperFactory = proc(
        mode: NATMode
    ): Opt[PortMapper] {.gcsafe, raises: [].} =
      Opt.some(PortMapper(mock))

    let switch = makeSwitch(upnpConfig(), @[TcpAutoAddress], factory)
    await switch.start()
    defer:
      await switch.stop()

    discard await switch.peerInfo.addressMappers[0](@[ma("/ip4/192.168.1.10/tcp/4242")])
    discard await switch.peerInfo.addressMappers[0](@[])

    check Port(7000) in mock.unmappedPorts()

  asyncTest "Upnp falls back to listenAddrs when discovery fails":
    let mock = newMock(discoverErr = Opt.some("no IGD"))
    let factory: PortMapperFactory = proc(
        mode: NATMode
    ): Opt[PortMapper] {.gcsafe, raises: [].} =
      Opt.some(PortMapper(mock))

    let switch = makeSwitch(upnpConfig(), @[TcpAutoAddress], factory)
    await switch.start()
    defer:
      await switch.stop()

    let priv = @[ma("/ip4/192.168.1.10/tcp/4242")]
    let res = await switch.peerInfo.addressMappers[0](priv)
    check res == priv # fall-through preserves the next mapper's input
    check mock.countCalls(mckMap) == 0

  asyncTest "Upnp inactive when factory returns none":
    let factory: PortMapperFactory = proc(
        mode: NATMode
    ): Opt[PortMapper] {.gcsafe, raises: [].} =
      Opt.none(PortMapper)

    let switch = makeSwitch(upnpConfig(), @[TcpAutoAddress], factory)
    await switch.start()
    defer:
      await switch.stop()

    # No addressMapper installed; peerInfo.addrs falls back to listenAddrs.
    check switch.peerInfo.addressMappers.len == 0
    check switch.peerInfo.addrs == switch.peerInfo.listenAddrs

  asyncTest "stop unmaps active mappings and closes the mapper":
    let mock = newMock(extPorts = @[Port(5555)])
    let factory: PortMapperFactory = proc(
        mode: NATMode
    ): Opt[PortMapper] {.gcsafe, raises: [].} =
      Opt.some(PortMapper(mock))

    let switch = makeSwitch(upnpConfig(), @[TcpAutoAddress], factory)
    await switch.start()
    discard await switch.peerInfo.addressMappers[0](@[ma("/ip4/192.168.1.10/tcp/4242")])
    await switch.stop()

    check Port(5555) in mock.unmappedPorts()
    check mock.countCalls(mckClose) == 1

  asyncTest "setup raises when Upnp config has zero refreshInterval":
    let cfg = upnpConfig(refreshInterval = 0.seconds)
    expect ServiceSetupError:
      discard makeSwitch(cfg, @[TcpAutoAddress])

  asyncTest "setup raises when NatPmp config has zero discoveryTimeout":
    let cfg = natPmpConfig(discoveryTimeout = 0.seconds)
    expect ServiceSetupError:
      discard makeSwitch(cfg, @[TcpAutoAddress])

  asyncTest "factory receives the configured mode":
    var seenMode = Auto
    let mock = newMock()
    let factory: PortMapperFactory = proc(
        mode: NATMode
    ): Opt[PortMapper] {.gcsafe, raises: [].} =
      seenMode = mode
      Opt.some(PortMapper(mock))

    let switch = makeSwitch(natPmpConfig(), @[TcpAutoAddress], factory)
    await switch.start()
    defer:
      await switch.stop()

    check seenMode == NatPmp

  asyncTest "map failure leaves no stale entry; announced falls through":
    let mock = newMock(extPorts = @[Port(8000)], mapErr = Opt.some("mapping refused"))
    let factory: PortMapperFactory = proc(
        mode: NATMode
    ): Opt[PortMapper] {.gcsafe, raises: [].} =
      Opt.some(PortMapper(mock))

    let switch = makeSwitch(upnpConfig(), @[TcpAutoAddress], factory)
    await switch.start()
    defer:
      await switch.stop()

    let priv = @[ma("/ip4/192.168.1.10/tcp/4242")]
    let res = await switch.peerInfo.addressMappers[0](priv)
    # No successful mapping → addressMapper falls back to listenAddrs unchanged.
    check res == priv
    check mock.countCalls(mckMap) == 1
    check mock.unmappedPorts().len == 0

  asyncTest "non-IPv4 private addrs are skipped":
    # nim-nat-traversal's UPnP backend doesn't support IPv6 mappings, so any
    # IPv6 listenAddr (even ULA fc00::/7) must be filtered out before map().
    let mock = newMock()
    let factory: PortMapperFactory = proc(
        mode: NATMode
    ): Opt[PortMapper] {.gcsafe, raises: [].} =
      Opt.some(PortMapper(mock))

    let switch = makeSwitch(upnpConfig(), @[TcpAutoAddress], factory)
    await switch.start()
    defer:
      await switch.stop()

    let res = await switch.peerInfo.addressMappers[0](@[ma("/ip6/fc00::1/tcp/4242")])
    check res == @[ma("/ip6/fc00::1/tcp/4242")] # fall-through, no map()
    check mock.countCalls(mckMap) == 0

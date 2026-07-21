# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sequtils]
import chronos, chronicles, results
import ../[multiaddress, multicodec, wire]
import ../switch
import ../crypto/crypto
import ./nat/[portmapper, plum_mapper]
import ../protocols/connectivity/autonat/[client, service]
import ../protocols/connectivity/autonatv2/[client, service]
import ../protocols/connectivity/relay/client as relayclient
import ./[autorelayservice, hpservice]

export portmapper
export OnReservationHandler, AutonatV2ServiceConfig, AutonatV2Service

logScope:
  topics = "libp2p natservice"

type
  AutonatVersion* = enum
    AutonatV1
    AutonatV2

  PortMappingMode* = enum
    ExplicitIp # static external IP
    Upnp # libplum restricted to UPnP-IGD
    NatPmp # libplum restricted to PCP / NAT-PMP
    Auto # libplum tries all protocols (PCP -> NAT-PMP -> UPnP)

  PortMappingConfig* = object
    case mode*: PortMappingMode
    of ExplicitIp:
      explicitIp*: IpAddress
    of Upnp, NatPmp, Auto:
      discoveryTimeout*: Duration ## how long libplum probes for a gateway
      mappingTimeout*: Duration ## how long libplum waits for a mapping reply

  ReachabilityConfig* = object
    ## AutoNAT reachability probing. ``scheduleInterval`` tunes the v1 cadence;
    ## ``v2ServiceConfig`` configures the v2 service.
    version*: AutonatVersion
    scheduleInterval*: Opt[Duration]
    v2ServiceConfig*: Opt[AutonatV2ServiceConfig]

  HolePunchingConfig* = object
    ## DCUtR hole-punching; drives AutoNAT v1 + AutoRelay internally.
    maxNumRelays*: int
    onReservation*: OnReservationHandler
    scheduleInterval*: Opt[Duration]

  NATConfig* = object
    ## ``portMapping`` is independent; ``reachability`` and ``holePunching`` are
    ## mutually exclusive (HP drives its own AutoNAT v1) and rejected at setup.
    portMapping*: Opt[PortMappingConfig]
    reachability*: Opt[ReachabilityConfig]
    holePunching*: Opt[HolePunchingConfig]

  PortMapperFactory* =
    proc(mode: PortMappingMode): Opt[PortMapper] {.gcsafe, raises: [].}

  NATService* = ref object of Service
    config: NATConfig
    rng: Rng
    addressMapper: AddressMapper
    portMapperFactory: PortMapperFactory
    mapper: PortMapper
    mappedPorts: seq[(Port, MapProto)]
    externalIp*: Opt[IpAddress]
    reachability: Service # active AutoNAT v1 / v2 / HP, started/stopped polymorphically

const
  DefaultDiscoveryTimeout* = 10.seconds
  DefaultMappingTimeout* = 10.seconds

func toProtocolFilter(mode: PortMappingMode): ProtocolFilter =
  case mode
  of Upnp: ProtocolFilter.UPnP
  of NatPmp: ProtocolFilter.PCP
  else: ProtocolFilter.Any
    # Auto; ExplicitIp never builds a mapper

proc new*(
    T: typedesc[NATService],
    config: NATConfig,
    rng: Rng,
    portMapperFactory: PortMapperFactory = nil,
): T =
  T(config: config, rng: rng, portMapperFactory: portMapperFactory)

proc autonatV2Service*(self: NATService): Opt[AutonatV2Service] =
  ## The live AutoNAT v2 service when reachability uses AutonatV2, else none.
  if self.reachability of AutonatV2Service:
    return Opt.some(AutonatV2Service(self.reachability))
  Opt.none(AutonatV2Service)

proc natService*(switch: Switch): Opt[NATService] =
  ## The switch's NATService, if one was configured.
  for s in switch.services:
    if s of NATService:
      return Opt.some(NATService(s))
  Opt.none(NATService)

proc portMappingConfig(
    mode: PortMappingMode, discoveryTimeout, mappingTimeout: Duration
): NATConfig =
  case mode
  of ExplicitIp:
    raiseAssert "portMappingConfig requires a port-mapping mode, not ExplicitIp"
  of Upnp, NatPmp, Auto:
    NATConfig(
      portMapping: Opt.some(
        PortMappingConfig(
          mode: mode, discoveryTimeout: discoveryTimeout, mappingTimeout: mappingTimeout
        )
      )
    )

proc natConfig*(
    discoveryTimeout = DefaultDiscoveryTimeout, mappingTimeout = DefaultMappingTimeout
): NATConfig =
  ## Recommended default: let libplum try every protocol (PCP -> NAT-PMP ->
  ## UPnP-IGD) and use whichever the gateway answers.
  portMappingConfig(Auto, discoveryTimeout, mappingTimeout)

proc upnpConfig*(
    discoveryTimeout = DefaultDiscoveryTimeout, mappingTimeout = DefaultMappingTimeout
): NATConfig =
  ## Restrict libplum to UPnP-IGD.
  portMappingConfig(Upnp, discoveryTimeout, mappingTimeout)

proc natPmpConfig*(
    discoveryTimeout = DefaultDiscoveryTimeout, mappingTimeout = DefaultMappingTimeout
): NATConfig =
  ## Restrict libplum to PCP / NAT-PMP.
  portMappingConfig(NatPmp, discoveryTimeout, mappingTimeout)

proc explicitIpConfig*(explicitIp: IpAddress): NATConfig =
  ## Announce ``explicitIp`` as the external IP; no port-mapping is performed.
  NATConfig(
    portMapping: Opt.some(PortMappingConfig(mode: ExplicitIp, explicitIp: explicitIp))
  )

proc autonatConfig*(
    version: AutonatVersion,
    scheduleInterval = Opt.none(Duration),
    v2ServiceConfig = Opt.none(AutonatV2ServiceConfig),
): NATConfig =
  ## Probe-only AutoNAT (no port-mapping, no hole-punching).
  NATConfig(
    reachability: Opt.some(
      ReachabilityConfig(
        version: version,
        scheduleInterval: scheduleInterval,
        v2ServiceConfig: v2ServiceConfig,
      )
    )
  )

proc holePunchingConfig*(
    maxNumRelays: int = 1,
    onReservation: OnReservationHandler = nil,
    scheduleInterval = Opt.none(Duration),
): NATConfig =
  ## AutoNAT v1 + AutoRelay + DCUtR. Hole-punching with v2 is not supported.
  NATConfig(
    holePunching: Opt.some(
      HolePunchingConfig(
        maxNumRelays: maxNumRelays,
        onReservation: onReservation,
        scheduleInterval: scheduleInterval,
      )
    )
  )

proc portMapping(self: NATService): PortMappingConfig =
  self.config.portMapping.expect(
    "portMapping accessed without an active port-mapping config"
  )

proc mergeInto*(dst: var NATConfig, src: NATConfig) =
  ## Fold ``src``'s set concerns into ``dst``; setting one concern twice is a
  ## programmer error (build-time misuse), so it fails fast with a Defect.
  src.portMapping.withValue(v):
    doAssert dst.portMapping.isNone(), "withNAT: portMapping configured more than once"
    dst.portMapping = Opt.some(v)
  src.reachability.withValue(v):
    doAssert dst.reachability.isNone(),
      "withNAT: reachability configured more than once"
    dst.reachability = Opt.some(v)
  src.holePunching.withValue(v):
    doAssert dst.holePunching.isNone(),
      "withNAT: holePunching configured more than once"
    dst.holePunching = Opt.some(v)

proc explicitIpMapped*(
    listenAddrs: seq[MultiAddress], explicitIp: IpAddress
): seq[MultiAddress] =
  ## For each listen address that carries an IP component matching the family
  ## of ``explicitIp``, emit a copy with the IP swapped to ``explicitIp``.
  ## Transport, port, and any suffix (e.g. ``/quic-v1``, ``/ws``, ``/wss``,
  ## ``/tls/ws``) are preserved. Addresses without an IP component, or with a
  ## mismatching family, are dropped. Duplicates (which can arise when the
  ## wildcard resolver expands a wildcard listen addr across multiple
  ## interfaces sharing the same port) are collapsed.
  var addrs: seq[MultiAddress]
  for listenAddr in listenAddrs:
    let ip = listenAddr.getIp().valueOr:
      continue
    if ip.family != explicitIp.family:
      continue
    listenAddr.replaceIp(explicitIp).withValue(remapped):
      if remapped notin addrs:
        addrs.add(remapped)
  addrs

type ListenPort = tuple[port: Port, proto: MapProto, multiAddr: MultiAddress]

proc transportProto(ma: MultiAddress): Opt[MapProto] =
  if ma[multiCodec("tcp")].isOk:
    Opt.some(mpTcp)
  elif ma[multiCodec("udp")].isOk:
    Opt.some(mpUdp)
  else:
    Opt.none(MapProto)

proc replaceTransportPort(ma: MultiAddress, port: Port): Opt[MultiAddress] =
  ## Mirrors ``MultiAddress.replaceIp`` but for the tcp/udp port component.
  let
    tcp = multiCodec("tcp")
    udp = multiCodec("udp")
  var res = MultiAddress.init()
  for item in ma.items:
    let part = item.valueOr:
      return Opt.none(MultiAddress)
    let code = part.protoCode.valueOr:
      return Opt.none(MultiAddress)
    if code == tcp or code == udp:
      let portMa = MultiAddress.init(code, int(port)).valueOr:
        return Opt.none(MultiAddress)
      res.append(portMa).isOkOr:
        return Opt.none(MultiAddress)
    else:
      res.append(part).isOkOr:
        return Opt.none(MultiAddress)
  Opt.some(res)

proc extractListenPort(ma: MultiAddress): Opt[ListenPort] =
  # libplum maps IPv4 only, so drop non-IPv4 listen addresses early.
  let ta = initTAddress(ma).valueOr:
    return Opt.none(ListenPort)
  if ta.family != AddressFamily.IPv4:
    return Opt.none(ListenPort)
  let proto = transportProto(ma).valueOr:
    return Opt.none(ListenPort)
  Opt.some((port: ta.port, proto: proto, multiAddr: ma))

proc buildAnnouncedAddr(
    listenAddr: MultiAddress, externalIp: IpAddress, externalPort: Port
): Opt[MultiAddress] =
  if externalIp.family != IpAddressFamily.IPv4:
    return Opt.none(MultiAddress)
  let withIp = listenAddr.replaceIp(externalIp).valueOr:
    return Opt.none(MultiAddress)
  let srcTa = initTAddress(listenAddr).valueOr:
    return Opt.some(withIp)
  if srcTa.port == externalPort:
    return Opt.some(withIp)
  replaceTransportPort(withIp, externalPort)

proc findMappableListenPorts(listenAddrs: seq[MultiAddress]): seq[ListenPort] =
  listenAddrs
    .filterIt(it.isPrivateMA)
    .mapIt(extractListenPort(it))
    .filterIt(it.isSome)
    .mapIt(it.get())

type MappedEntry =
  tuple[entry: (Port, MapProto), externalIp: IpAddress, announced: Opt[MultiAddress]]

proc mapOnePort(
    self: NATService, lp: ListenPort
): Future[Opt[MappedEntry]] {.async: (raises: [CancelledError]).} =
  # libplum returns the external address with the mapping; no separate discovery.
  let mapped = (await self.mapper.map(lp.port, lp.port, lp.proto)).valueOr:
    warn "NAT port mapping failed", port = lp.port, proto = lp.proto, err = error
    return Opt.none(MappedEntry)

  Opt.some(
    (
      entry: (mapped.externalPort, lp.proto),
      externalIp: mapped.externalIp,
      announced:
        buildAnnouncedAddr(lp.multiAddr, mapped.externalIp, mapped.externalPort),
    )
  )

proc unmapStale(
    self: NATService, keep: seq[(Port, MapProto)]
) {.async: (raises: [CancelledError]).} =
  ## Unmap any (extPort, proto) entries that were active in the previous
  ## refresh cycle but are no longer part of the desired mapping set. Covers
  ## both listenAddr removals and IGDs returning a different external port on
  ## the next map() (e.g. when the requested external port becomes busy).
  for entry in self.mappedPorts:
    if entry in keep:
      continue
    let (port, proto) = entry
    let r = await self.mapper.unmap(port, proto)
    if r.isErr:
      warn "Failed to unmap stale port", port, proto, err = r.error

proc unmapAll(self: NATService) {.async: (raises: [CancelledError]).} =
  await self.unmapStale(@[])
  self.mappedPorts.setLen(0)

proc setupMappings*(
    self: NATService, listenAddrs: seq[MultiAddress]
): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
  ## Request a mapping for every private listen address; updates ``externalIp``
  ## and ``mappedPorts`` as a side-effect, and tears down mappings that are no
  ## longer needed.
  if self.mapper.isNil:
    debug "No port mapper available; skipping NAT port mapping"
    return @[]

  let listenPorts = findMappableListenPorts(listenAddrs)
  if listenPorts.len == 0:
    debug "No private listen addresses to map; releasing any prior mappings"
    await self.unmapAll()
    return @[]

  var
    nextMapped: seq[(Port, MapProto)]
    announced: seq[MultiAddress] = listenAddrs.filterIt(not it.isPrivateMA)
    externalIp = Opt.none(IpAddress)

  for lp in listenPorts:
    (await self.mapOnePort(lp)).withValue(res):
      externalIp = Opt.some(res.externalIp)
      if res.entry notin nextMapped:
        nextMapped.add(res.entry)

      res.announced.withValue(annAddr):
        if annAddr notin announced:
          announced.add(annAddr)

  self.externalIp = externalIp
  await self.unmapStale(nextMapped)
  self.mappedPorts = nextMapped
  announced

proc validatePortMapperConfig(cfg: PortMappingConfig) {.raises: [ServiceSetupError].} =
  # libplum refreshes mappings itself; only the discovery/mapping waits need checking.
  if cfg.discoveryTimeout <= 0.seconds:
    raise newException(
      ServiceSetupError,
      "NATService: discoveryTimeout must be > 0; use natConfig/upnpConfig/natPmpConfig",
    )
  if cfg.mappingTimeout <= 0.seconds:
    raise newException(
      ServiceSetupError,
      "NATService: mappingTimeout must be > 0; use natConfig/upnpConfig/natPmpConfig",
    )

proc setupHolePunching(
    self: NATService, switch: Switch, hp: HolePunchingConfig
) {.raises: [ServiceSetupError].} =
  if hp.maxNumRelays < 1:
    raise newException(
      ServiceSetupError,
      "NATService: holePunching maxNumRelays must be >= 1; use holePunchingConfig",
    )
  let
    autonatService = AutonatService.new(
      AutonatClient(), self.rng, scheduleInterval = hp.scheduleInterval
    )
    autoRelayService = AutoRelayService.new(
      hp.maxNumRelays, RelayClient.new(), hp.onReservation, self.rng
    )
    hpService = HPService.new(autonatService, autoRelayService)
  hpService.setup(switch)
  self.reachability = hpService

proc setupAutonatV1(
    self: NATService, switch: Switch, r: ReachabilityConfig
) {.raises: [].} =
  let autonatService =
    AutonatService.new(AutonatClient(), self.rng, scheduleInterval = r.scheduleInterval)
  autonatService.setup(switch)
  self.reachability = autonatService

proc setupAutonatV2(
    self: NATService, switch: Switch, r: ReachabilityConfig
) {.raises: [ServiceSetupError].} =
  let
    serviceConfig = r.v2ServiceConfig.valueOr:
      AutonatV2ServiceConfig.new()
    autonatV2Client = AutonatV2Client.new(self.rng)
    autonatV2Service =
      AutonatV2Service.new(self.rng, client = autonatV2Client, config = serviceConfig)
  autonatV2Client.setup(switch)
  try:
    switch.mount(autonatV2Client)
  except LPError as e:
    raise newException(
      ServiceSetupError, "NATService failed to mount AutonatV2Client: " & e.msg
    )
  autonatV2Service.setup(switch)
  self.reachability = autonatV2Service

proc setupReachability(
    self: NATService, switch: Switch
) {.raises: [ServiceSetupError].} =
  if self.config.holePunching.isNone() and self.config.reachability.isNone():
    return
  # HP already drives its own AutoNAT v1, so pairing it with reachability is contradictory.
  if self.config.holePunching.isSome() and self.config.reachability.isSome():
    raise newException(
      ServiceSetupError,
      "NATService: holePunching and reachability are mutually exclusive; " &
        "holePunching already runs AutoNAT v1.",
    )
  self.config.holePunching.withValue(hp):
    self.setupHolePunching(switch, hp)
    return
  self.config.reachability.withValue(r):
    case r.version
    of AutonatV1:
      self.setupAutonatV1(switch, r)
    of AutonatV2:
      self.setupAutonatV2(switch, r)

method setup*(self: NATService, switch: Switch) {.raises: [ServiceSetupError].} =
  debug "Setting up NATService",
    portMapping = self.config.portMapping.isSome(),
    reachability = self.config.reachability.isSome(),
    holePunching = self.config.holePunching.isSome()

  self.config.portMapping.withValue(pm):
    if pm.mode in {Upnp, NatPmp, Auto}:
      validatePortMapperConfig(pm)

  self.setupReachability(switch)

proc explicitIpMapper(explicitIp: IpAddress): AddressMapper =
  proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    explicitIpMapped(listenAddrs, explicitIp)

proc portMappingMapper(self: NATService): AddressMapper =
  proc(
      listenAddrs: seq[MultiAddress]
  ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
    let announced = await self.setupMappings(listenAddrs)
    # Nothing mapped: pass listenAddrs through so the next mapper still has input.
    if announced.len == 0:
      return listenAddrs
    announced

proc buildPortMapper(self: NATService, mode: PortMappingMode): Opt[PortMapper] =
  if not self.portMapperFactory.isNil():
    return self.portMapperFactory(mode)

  let pm = self.portMapping()
  let mapper = PlumMapper.new(
    mode.toProtocolFilter(), pm.discoveryTimeout, pm.mappingTimeout
  ).valueOr:
    error "Failed to construct libplum port mapper", mode, err = error
    return Opt.none(PortMapper)
  Opt.some(PortMapper(mapper))

proc startPortMapping(self: NATService, switch: Switch) =
  ## (Re)build the addressMapper here, not in setup, so a stop/start cycle
  ## re-creates it after stop() tears it down.
  self.config.portMapping.withValue(pm):
    case pm.mode
    of ExplicitIp:
      self.addressMapper = explicitIpMapper(pm.explicitIp)
    of Upnp, NatPmp, Auto:
      self.mapper = self.buildPortMapper(pm.mode).valueOr:
        warn "Could not build port mapper; port mapping inactive", mode = pm.mode
        return
      self.addressMapper = self.portMappingMapper()

  if not self.addressMapper.isNil():
    switch.peerInfo.addressMappers.add(self.addressMapper)

proc startReachability(
    self: NATService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  if not self.reachability.isNil():
    await self.reachability.start(switch)

method start*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Starting NATService"
  self.startPortMapping(switch)
  await self.startReachability(switch)

proc stopPortMapping(
    self: NATService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  ## Deliberately never call peerInfo.update() during shutdown: user-set
  ## announcedAddrs must survive and observers must not broadcast mid-teardown.
  self.config.portMapping.withValue(pm):
    case pm.mode
    of ExplicitIp:
      if not self.addressMapper.isNil():
        switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
        self.addressMapper = nil
    of Upnp, NatPmp, Auto:
      if not self.addressMapper.isNil():
        switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
        self.addressMapper = nil
      if not self.mapper.isNil():
        await self.unmapAll()
        await self.mapper.close()
        self.mapper = nil
      self.externalIp = Opt.none(IpAddress)

proc stopReachability(
    self: NATService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  if not self.reachability.isNil():
    await self.reachability.stop(switch)

method stop*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Stopping NATService"
  await self.stopPortMapping(switch)
  await self.stopReachability(switch)

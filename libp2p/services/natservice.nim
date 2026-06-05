# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sequtils]
import chronos, chronicles, results
import ../[multiaddress, multicodec, wire]
import ../switch
import ../crypto/crypto
import ../utils/heartbeat
import ./nat/[portmapper, upnp_mapper, natpmp_mapper]
import ../protocols/connectivity/autonat/[client, service]
import ../protocols/connectivity/autonatv2/[client, service]
import ../protocols/connectivity/relay/client as relayclient
import ./[autorelayservice, hpservice]

export portmapper
export OnReservationHandler, AutonatV2ServiceConfig

logScope:
  topics = "libp2p natservice"

type
  AutonatVersion* = enum
    AutonatV1
    AutonatV2

  NATMode* = enum
    Auto # autonat/hole-punching
    ExplicitIp # static external IP
    Upnp
    NatPmp

  NATConfig* = object
    ## Hole-punching uses AutoNAT v1; pairing it with ``autonat = some(AutonatV2)`` is rejected at setup.
    autonat*: Opt[AutonatVersion]
    enableHolePunching*: bool
    maxNumRelays*: int
    onReservation*: OnReservationHandler
    autonatV1ScheduleInterval*: Opt[Duration]
    autonatV2ServiceConfig*: Opt[AutonatV2ServiceConfig]
    case mode*: NATMode
    of ExplicitIp:
      explicitIp*: IpAddress
    of Auto:
      discard
    of Upnp, NatPmp:
      refreshInterval*: Duration
      discoveryTimeout*: Duration
      leaseDuration*: Duration

  PortMapperFactory* = proc(mode: NATMode): Opt[PortMapper] {.gcsafe, raises: [].}

  NATService* = ref object of Service
    config: NATConfig
    rng: Rng
    addressMapper: AddressMapper
    portMapperFactory: PortMapperFactory
    mapper: PortMapper
    refreshLoopFut: Future[void]
    mappedPorts: seq[(Port, MapProto)]
    externalIp*: Opt[IpAddress]
    # AutoNAT / hole-punching sub-services. Populated by setup() based on config.
    autonatService*: AutonatService
    autonatV2Service*: AutonatV2Service
    autonatV2Client*: AutonatV2Client
    autoRelayService*: AutoRelayService
    hpService*: HPService

const
  DefaultRefreshInterval* = 30.minutes
  DefaultDiscoveryTimeout* = 10.seconds
  DefaultLeaseDuration* = 1.hours

proc defaultPortMapperFactory(mode: NATMode): Opt[PortMapper] {.gcsafe, raises: [].} =
  try:
    case mode
    of Upnp:
      Opt.some(PortMapper(UpnpMapper.new()))
    of NatPmp:
      Opt.some(PortMapper(NatPmpMapper.new()))
    of Auto, ExplicitIp:
      Opt.none(PortMapper)
  except ResourceExhaustedError as e:
    error "Failed to construct port mapper", mode, err = e.msg
    Opt.none(PortMapper)

proc new*(
    T: typedesc[NATService],
    config: NATConfig,
    rng: Rng,
    portMapperFactory: PortMapperFactory = nil,
): T =
  ## ``rng`` is forwarded to the AutoNAT / AutoRelay sub-services when
  ## ``config.autonat`` or ``config.enableHolePunching`` is set.
  T(config: config, rng: rng, portMapperFactory: portMapperFactory)

proc upnpConfig*(
    refreshInterval = DefaultRefreshInterval,
    discoveryTimeout = DefaultDiscoveryTimeout,
    leaseDuration = DefaultLeaseDuration,
): NATConfig =
  NATConfig(
    mode: Upnp,
    refreshInterval: refreshInterval,
    discoveryTimeout: discoveryTimeout,
    leaseDuration: leaseDuration,
  )

proc natPmpConfig*(
    refreshInterval = DefaultRefreshInterval,
    discoveryTimeout = DefaultDiscoveryTimeout,
    leaseDuration = DefaultLeaseDuration,
): NATConfig =
  NATConfig(
    mode: NatPmp,
    refreshInterval: refreshInterval,
    discoveryTimeout: discoveryTimeout,
    leaseDuration: leaseDuration,
  )

proc autonatConfig*(
    version: AutonatVersion,
    scheduleInterval = Opt.none(Duration),
    v2ServiceConfig = Opt.none(AutonatV2ServiceConfig),
): NATConfig =
  ## Probe-only AutoNAT (no port-mapping, no hole-punching).
  NATConfig(
    mode: Auto,
    autonat: Opt.some(version),
    autonatV1ScheduleInterval: scheduleInterval,
    autonatV2ServiceConfig: v2ServiceConfig,
  )

proc holePunchingConfig*(
    maxNumRelays: int = 1,
    onReservation: OnReservationHandler = nil,
    scheduleInterval = Opt.none(Duration),
): NATConfig =
  ## AutoNAT v1 + AutoRelay + DCUtR. Hole-punching with v2 is not supported.
  NATConfig(
    mode: Auto,
    autonat: Opt.some(AutonatV1),
    enableHolePunching: true,
    maxNumRelays: maxNumRelays,
    onReservation: onReservation,
    autonatV1ScheduleInterval: scheduleInterval,
  )

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
  # NAT-PMP only supports IPv4 and nim-nat-traversal's UPnP backend does not
  # yet support IPv6 mappings either, so drop non-IPv4 listen addresses early.
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

proc discoverExternalIp(
    self: NATService
): Future[Opt[IpAddress]] {.async: (raises: [CancelledError]).} =
  self.externalIp.withValue(externalIp):
    return Opt.some(externalIp)

  let discover = (await self.mapper.discover(self.config.discoveryTimeout)).valueOr:
    warn "NAT discovery failed; not announcing mapped addresses", err = error
    self.externalIp = Opt.none(IpAddress)
    return Opt.none(IpAddress)
  self.externalIp = Opt.some(discover)
  info "NAT discovery succeeded", externalIp = discover
  Opt.some(discover)

type MappedEntry = tuple[entry: (Port, MapProto), announced: Opt[MultiAddress]]

proc mapOnePort(
    self: NATService, lp: ListenPort, externalIp: IpAddress
): Future[Opt[MappedEntry]] {.async: (raises: [CancelledError]).} =
  let lease = uint32(self.config.leaseDuration.seconds)
  let extPort = (await self.mapper.map(lp.port, lp.port, lp.proto, lease)).valueOr:
    warn "NAT port mapping failed", port = lp.port, proto = lp.proto, err = error
    return Opt.none(MappedEntry)

  Opt.some(
    (
      entry: (extPort, lp.proto),
      announced: buildAnnouncedAddr(lp.multiAddr, externalIp, extPort),
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

  let externalIp = (await self.discoverExternalIp()).valueOr:
    debug "Could not find external IP; releasing any prior mappings"
    await self.unmapAll()
    return @[]

  var
    nextMapped: seq[(Port, MapProto)]
    announced: seq[MultiAddress] = listenAddrs.filterIt(not it.isPrivateMA)

  for lp in listenPorts:
    (await self.mapOnePort(lp, externalIp)).withValue(res):
      if res.entry notin nextMapped:
        nextMapped.add(res.entry)

      res.announced.withValue(annAddr):
        if annAddr notin announced:
          announced.add(annAddr)

  await self.unmapStale(nextMapped)
  self.mappedPorts = nextMapped
  announced

proc refreshLoop(
    self: NATService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  ## Trigger ``peerInfo.update()`` periodically so the addressMapper re-runs
  ## and reissues mappings before the lease expires. Invalidates the cached
  ## external IP first so DHCP renewals / failovers are picked up.
  heartbeat "NATService refresh", self.config.refreshInterval, sleepFirst = true:
    self.externalIp = Opt.none(IpAddress)
    await switch.peerInfo.update()

proc validatePortMapperConfig(cfg: NATConfig) {.raises: [ServiceSetupError].} =
  if cfg.refreshInterval <= 0.seconds:
    raise newException(
      ServiceSetupError,
      "NATService: refreshInterval must be > 0; use upnpConfig/natPmpConfig",
    )
  if cfg.discoveryTimeout <= 0.seconds:
    raise newException(
      ServiceSetupError,
      "NATService: discoveryTimeout must be > 0; use upnpConfig/natPmpConfig",
    )
  # NAT-PMP treats lease=0 as a delete, so the seconds-truncated lease must be
  # at least 1; sub-second durations would round to 0.
  if cfg.leaseDuration < 1.seconds:
    raise newException(
      ServiceSetupError,
      "NATService: leaseDuration must be >= 1s; use upnpConfig/natPmpConfig",
    )
  if cfg.refreshInterval >= cfg.leaseDuration:
    raise newException(
      ServiceSetupError,
      "NATService: refreshInterval must be < leaseDuration so mappings refresh before expiry",
    )

proc setupHolePunching(
    self: NATService, switch: Switch
) {.raises: [ServiceSetupError].} =
  if self.config.autonat == Opt.some(AutonatV2):
    raise newException(
      ServiceSetupError,
      "NATService: enableHolePunching currently requires AutoNAT v1; " &
        "set NATConfig.autonat to none or some(AutonatV1).",
    )
  let maxNumRelays = if self.config.maxNumRelays > 0: self.config.maxNumRelays else: 1
  self.autonatService = AutonatService.new(
    AutonatClient(), self.rng, scheduleInterval = self.config.autonatV1ScheduleInterval
  )
  self.autoRelayService = AutoRelayService.new(
    maxNumRelays, RelayClient.new(), self.config.onReservation, self.rng
  )
  self.hpService = HPService.new(self.autonatService, self.autoRelayService)
  self.hpService.setup(switch)

proc setupAutonatV1(self: NATService, switch: Switch) {.raises: [ServiceSetupError].} =
  self.autonatService = AutonatService.new(
    AutonatClient(), self.rng, scheduleInterval = self.config.autonatV1ScheduleInterval
  )
  self.autonatService.setup(switch)

proc setupAutonatV2(self: NATService, switch: Switch) {.raises: [ServiceSetupError].} =
  let serviceConfig =
    self.config.autonatV2ServiceConfig.get(AutonatV2ServiceConfig.new())
  self.autonatV2Client = AutonatV2Client.new(self.rng)
  self.autonatV2Service = AutonatV2Service.new(
    self.rng, client = self.autonatV2Client, config = serviceConfig
  )
  self.autonatV2Client.setup(switch)
  try:
    switch.mount(self.autonatV2Client)
  except LPError as e:
    raise newException(
      ServiceSetupError, "NATService failed to mount AutonatV2Client: " & e.msg
    )
  self.autonatV2Service.setup(switch)

proc setupAutonat(self: NATService, switch: Switch) {.raises: [ServiceSetupError].} =
  if self.config.enableHolePunching:
    self.setupHolePunching(switch)
  elif self.config.autonat == Opt.some(AutonatV1):
    self.setupAutonatV1(switch)
  elif self.config.autonat == Opt.some(AutonatV2):
    self.setupAutonatV2(switch)

method setup*(self: NATService, switch: Switch) {.raises: [ServiceSetupError].} =
  debug "Setting up NATService",
    mode = self.config.mode,
    autonat = self.config.autonat,
    enableHolePunching = self.config.enableHolePunching

  if self.config.mode in {Upnp, NatPmp}:
    validatePortMapperConfig(self.config)

  self.setupAutonat(switch)

method start*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Starting NATService", mode = self.config.mode

  # Construct the mapper and addressMapper here (not in setup) so a
  # stop()/start() cycle re-creates them after we tear them down in stop().
  case self.config.mode
  of Auto:
    discard
  of ExplicitIp:
    self.addressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      return explicitIpMapped(listenAddrs, self.config.explicitIp)
  of Upnp, NatPmp:
    let mapperOpt =
      if self.portMapperFactory.isNil:
        defaultPortMapperFactory(self.config.mode)
      else:
        self.portMapperFactory(self.config.mode)
    self.mapper = mapperOpt.valueOr:
      warn "Could not build port mapper; NATService inactive", mode = self.config.mode
      return
    self.addressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      let announced = await self.setupMappings(listenAddrs)
      # If we got nothing back (e.g. discovery failed, no private listenAddrs)
      # fall back to passing the listenAddrs through unchanged so the next
      # mapper in the chain has something to work with.
      if announced.len == 0:
        return listenAddrs
      return announced
    self.refreshLoopFut = self.refreshLoop(switch)

  if not self.addressMapper.isNil:
    switch.peerInfo.addressMappers.add(self.addressMapper)
  # peerInfo.update is invoked by Switch.start once transports have bound, at
  # which point the mapper runs against the resolved listenAddrs.

  if self.hpService != nil:
    await self.hpService.start(switch)
  elif self.autonatService != nil:
    await self.autonatService.start(switch)
  elif self.autonatV2Service != nil:
    await self.autonatV2Service.start(switch)

method stop*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Stopping NATService"

  case self.config.mode
  of Auto:
    discard
  of ExplicitIp:
    if not self.addressMapper.isNil:
      switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
      self.addressMapper = nil
    # Do not touch peerInfo.announcedAddrs here: those may have been set by the
    # user via withAnnouncedAddresses, and triggering peerInfo.update during
    # shutdown can cause observers (e.g. IdentifyPusher) to broadcast while the
    # switch is tearing down.
  of Upnp, NatPmp:
    if not self.refreshLoopFut.isNil:
      await self.refreshLoopFut.cancelAndWait()
      self.refreshLoopFut = nil
    if not self.addressMapper.isNil:
      switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
      self.addressMapper = nil
    if not self.mapper.isNil:
      await self.unmapAll()
      await self.mapper.close()
      self.mapper = nil
    self.externalIp = Opt.none(IpAddress)
    # Mirror the explicitIp path: deliberately do not call peerInfo.update()
    # during shutdown.

  if self.hpService != nil:
    await self.hpService.stop(switch)
  elif self.autonatService != nil:
    await self.autonatService.stop(switch)
  elif self.autonatV2Service != nil:
    await self.autonatV2Service.stop(switch)

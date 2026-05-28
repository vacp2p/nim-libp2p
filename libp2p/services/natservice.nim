# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sequtils]
import chronos, chronicles, results
import ./natservice/[port_mapper, miniupnpc_mapper, natpmp_mapper, mapped_addrs]
import ../multiaddress
import ../utils/heartbeat
import ../switch
import ../crypto/crypto
import ../protocols/connectivity/autonat/[client, service]
import ../protocols/connectivity/autonatv2/[client, service]
import ../protocols/connectivity/relay/client as relayclient
import ./[autorelayservice, hpservice]

export port_mapper, miniupnpc_mapper, natpmp_mapper, mapped_addrs
export OnReservationHandler, AutonatV2ServiceConfig

logScope:
  topics = "libp2p natservice"

type
  AutonatVersion* = enum
    AutonatV1
    AutonatV2

  NATMode* = enum
    Auto ## Rely on autonat / hole-punching only; no port-mapping.
    ExplicitIp ## Static external IP combined with bound listen ports.
    Upnp ## Request port mappings from a UPnP IGD.
    NatPmp ## Request port mappings via NAT-PMP (RFC 6886).

  NATConfig* = object
    ## ``autonat`` enables AutoNAT probing for the chosen version. When
    ## ``enableHolePunching`` is true, libp2p runs hole-punching (DCUtR) backed
    ## by AutoNAT v1 — pairing ``enableHolePunching`` with
    ## ``autonat = some(AutonatV2)`` is rejected at setup time. ``maxNumRelays``
    ## and ``onReservation`` configure the AutoRelay sub-service used by HP.
    autonat*: Opt[AutonatVersion]
    enableHolePunching*: bool
    maxNumRelays*: int
    onReservation*: OnReservationHandler
    autonatV1ScheduleInterval*: Opt[Duration]
    autonatV2ServiceConfig*: Opt[AutonatV2ServiceConfig]
    case mode*: NATMode
    of Auto:
      discard
    of ExplicitIp:
      explicitIp*: IpAddress
    of Upnp, NatPmp:
      description*: string ## Label shown by UPnP IGDs in their admin UI.
      refreshInterval*: Duration ## Renewal cadence; must be < ``leaseDuration``.
      leaseDuration*: Duration ## Lease lifetime requested from the gateway.

  NATService* = ref object of Service
    config: NATConfig
    rng: Rng
    addressMapper: AddressMapper
    # Port-mapping (Upnp / NatPmp)
    portMapper: NATPortMapper
    externalIp: Opt[IpAddress]
    activeMappings: seq[PortMapping]
    refreshFut: Future[void]
    # AutoNAT / hole-punching sub-services. Populated by setup() based on config.
    autonatService*: AutonatService
    autonatV2Service*: AutonatV2Service
    autonatV2Client*: AutonatV2Client
    autoRelayService*: AutoRelayService
    hpService*: HPService

const
  DefaultNATLeaseDuration* = 60.minutes
  DefaultNATDescription* = "nim-libp2p"

proc new*(
    T: typedesc[NATConfig],
    mode: NATMode,
    description = DefaultNATDescription,
    refreshInterval = Opt.none(Duration),
    leaseDuration = DefaultNATLeaseDuration,
): T =
  ## For ``Auto``, ``Upnp``, or ``NatPmp``. Use the ``explicitIp`` overload
  ## for ``ExplicitIp``. When ``refreshInterval`` is unset, it defaults to
  ## ``leaseDuration div 2``.
  case mode
  of Auto:
    NATConfig(mode: Auto)
  of Upnp:
    # leaseDuration == 0 asks UPnP for an infinite lease — caller must then
    # set refreshInterval explicitly.
    doAssert leaseDuration > 0.seconds or refreshInterval.isSome,
      "refreshInterval must be set when leaseDuration is 0 (infinite UPnP lease)"
    let refresh = refreshInterval.valueOr:
      leaseDuration div 2
    doAssert refresh > 0.seconds, "refreshInterval must be positive"
    if leaseDuration > 0.seconds:
      doAssert refresh < leaseDuration,
        "refreshInterval must be less than leaseDuration"
    NATConfig(
      mode: Upnp,
      description: description,
      refreshInterval: refresh,
      leaseDuration: leaseDuration,
    )
  of NatPmp:
    doAssert leaseDuration > 0.seconds, "NAT-PMP requires leaseDuration > 0"
    let refresh = refreshInterval.valueOr:
      leaseDuration div 2
    doAssert refresh > 0.seconds and refresh < leaseDuration,
      "refreshInterval must be in (0, leaseDuration)"
    NATConfig(
      mode: NatPmp,
      description: description,
      refreshInterval: refresh,
      leaseDuration: leaseDuration,
    )
  of ExplicitIp:
    raiseAssert "use NATConfig.new(explicitIp) for ExplicitIp"

proc new*(T: typedesc[NATConfig], explicitIp: IpAddress): T =
  NATConfig(mode: ExplicitIp, explicitIp: explicitIp)

proc new*(
    T: typedesc[NATService],
    config: NATConfig,
    rng: Rng,
    portMapper: NATPortMapper = nil,
): T =
  ## ``rng`` is forwarded to the AutoNAT / AutoRelay sub-services when
  ## ``config.autonat`` or ``config.enableHolePunching`` is set. Optional
  ## ``portMapper`` overrides the default backend; when ``nil`` and
  ## ``config.mode`` is ``Upnp``/``NatPmp``, setup builds the production mapper.
  T(config: config, rng: rng, portMapper: portMapper)

proc acquireMappings(
    self: NATService, listenAddrs: seq[MultiAddress]
): Result[void, string] =
  ## Discover the external IP and request a mapping per listen address.
  ## Populates ``externalIp``/``activeMappings``. Safe to call repeatedly.
  ## TODO: ``NATPortMapper`` methods are blocking (miniupnpc discover takes
  ## seconds). This proc runs on the chronos event loop via both the address
  ## mapper and ``refreshLoop`` — offload to a worker thread once chronos
  ## ``ThreadSignalPtr``-based plumbing is wired up.
  let extIp = ?self.portMapper.discoverExternalIp()
  let wanted = collectInternalPorts(listenAddrs)
  if wanted.len == 0:
    return err("NAT: no TCP/UDP listen addresses to map")
  var acquired: seq[PortMapping]
  for m in wanted:
    let extPort = self.portMapper.addMapping(
      m.internalPort, m.protocol, self.config.leaseDuration, self.config.description
    ).valueOr:
      warn "NAT mapping failed",
        port = m.internalPort, protocol = m.protocol, error = error
      continue
    acquired.add(
      PortMapping(
        internalPort: m.internalPort, externalPort: extPort, protocol: m.protocol
      )
    )
  if acquired.len == 0:
    return err("NAT: no port mappings were acquired")
  if acquired.len < wanted.len:
    warn "NAT: only some port mappings were acquired",
      acquired = acquired.len, requested = wanted.len
  self.externalIp = Opt.some(extIp)
  self.activeMappings = acquired
  ok()

method setup*(self: NATService, switch: Switch) {.raises: [ServiceSetupError].} =
  debug "Setting up NATService",
    mode = self.config.mode,
    autonat = self.config.autonat,
    enableHolePunching = self.config.enableHolePunching

  case self.config.mode
  of Auto:
    discard
  of ExplicitIp:
    self.addressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      return explicitIpMapped(listenAddrs, self.config.explicitIp)
  of Upnp, NatPmp:
    if self.portMapper == nil:
      try:
        self.portMapper =
          case self.config.mode
          of Upnp:
            newMiniupnpcMapper()
          of NatPmp:
            newNatPmpMapper()
          else:
            nil
      except NATMapperError as e:
        raise
          newException(ServiceSetupError, "NAT mapper construction failed: " & e.msg)
    self.addressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      # First call runs at the tail of ``Switch.start``, after transports have
      # bound real ports — that's when we actually ask the gateway.
      if self.externalIp.isNone:
        self.acquireMappings(listenAddrs).isOkOr:
          warn "NAT initial mapping failed", error = error
          return @[]
      let extIp = self.externalIp.valueOr:
        return @[]
      return gatewayMapped(listenAddrs, extIp, self.activeMappings)

  if self.config.enableHolePunching:
    if self.config.autonat == Opt.some(AutonatV2):
      raise newException(
        ServiceSetupError,
        "NATService: enableHolePunching currently requires AutoNAT v1; " &
          "set NATConfig.autonat to none or some(AutonatV1).",
      )
    let
      maxNumRelays = if self.config.maxNumRelays > 0: self.config.maxNumRelays else: 1
      autonatService = AutonatService.new(
        AutonatClient(),
        self.rng,
        scheduleInterval = self.config.autonatV1ScheduleInterval,
      )
      autoRelayService = AutoRelayService.new(
        maxNumRelays, RelayClient.new(), self.config.onReservation, self.rng
      )
    self.autonatService = autonatService
    self.autoRelayService = autoRelayService
    self.hpService = HPService.new(autonatService, autoRelayService)
    self.hpService.setup(switch)
  elif self.config.autonat == Opt.some(AutonatV1):
    self.autonatService = AutonatService.new(
      AutonatClient(),
      self.rng,
      scheduleInterval = self.config.autonatV1ScheduleInterval,
    )
    self.autonatService.setup(switch)
  elif self.config.autonat == Opt.some(AutonatV2):
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

proc refreshLoop(
    self: NATService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  heartbeat "nat refresh", self.config.refreshInterval, sleepFirst = true:
    self.acquireMappings(switch.peerInfo.listenAddrs).isOkOr:
      warn "NAT mapping refresh failed", error = error
      continue
    await switch.peerInfo.update()

method start*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Starting NATService", mode = self.config.mode
  if self.addressMapper != nil:
    switch.peerInfo.addressMappers.add(self.addressMapper)
  case self.config.mode
  of Upnp, NatPmp:
    # Initial mapping is acquired lazily by the addressMapper; the refresh
    # loop only renews, so its first tick must sleep before doing any work.
    self.refreshFut = self.refreshLoop(switch)
  else:
    discard

  if self.hpService != nil:
    await self.hpService.start(switch)
  elif self.autonatService != nil:
    await self.autonatService.start(switch)
  elif self.autonatV2Service != nil:
    await self.autonatV2Service.start(switch)

method stop*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Stopping NATService"
  if self.refreshFut != nil and not self.refreshFut.finished:
    await self.refreshFut.cancelAndWait()
    self.refreshFut = nil
  if self.portMapper != nil:
    for m in self.activeMappings:
      self.portMapper.deleteMapping(m.externalPort, m.internalPort, m.protocol).isOkOr:
        debug "NAT delete mapping failed (best-effort)",
          port = m.externalPort, protocol = m.protocol, error = error
    self.portMapper.close()
  self.activeMappings = @[]
  self.externalIp = Opt.none(IpAddress)
  if self.addressMapper != nil:
    switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
  # Don't touch peerInfo.announcedAddrs / call peerInfo.update here — it can
  # make observers (e.g. IdentifyPusher) broadcast mid-shutdown.

  if self.hpService != nil:
    await self.hpService.stop(switch)
  elif self.autonatService != nil:
    await self.autonatService.stop(switch)
  elif self.autonatV2Service != nil:
    await self.autonatV2Service.stop(switch)

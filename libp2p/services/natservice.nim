# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sequtils]
import chronos, chronicles, results
import ./natservice/[port_mapper, miniupnpc_mapper, natpmp_mapper, mapped_addrs]
import ../multiaddress
import ../utils/heartbeat
import ../switch

export port_mapper, miniupnpc_mapper, natpmp_mapper, mapped_addrs

logScope:
  topics = "libp2p natservice"

type
  NATMode* = enum
    Auto ## No port mapping; relies on autonat/hole-punching. TODO: not yet wired.
    ExplicitIp ## Static external IP combined with bound listen ports.
    Upnp ## Request port mappings from a UPnP IGD.
    NatPmp ## Request port mappings via NAT-PMP (RFC 6886).

  NATConfig* = object
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
    addressMapper: AddressMapper
    portMapper: NATPortMapper
    externalIp: Opt[IpAddress]
    activeMappings: seq[PortMapping]
    refreshFut: Future[void]

const
  DefaultNATRefreshInterval* = 20.minutes
  DefaultNATLeaseDuration* = 60.minutes
  DefaultNATDescription* = "nim-libp2p"

proc new*(
    T: typedesc[NATConfig],
    mode: NATMode,
    description = DefaultNATDescription,
    refreshInterval = DefaultNATRefreshInterval,
    leaseDuration = DefaultNATLeaseDuration,
): T =
  ## For ``Auto``, ``Upnp``, or ``NatPmp``. Use the ``explicitIp`` overload
  ## for ``ExplicitIp``.
  case mode
  of Auto:
    NATConfig(mode: Auto)
  of Upnp:
    NATConfig(
      mode: Upnp,
      description: description,
      refreshInterval: refreshInterval,
      leaseDuration: leaseDuration,
    )
  of NatPmp:
    NATConfig(
      mode: NatPmp,
      description: description,
      refreshInterval: refreshInterval,
      leaseDuration: leaseDuration,
    )
  of ExplicitIp:
    raiseAssert "use NATConfig.new(explicitIp) for ExplicitIp"

proc new*(T: typedesc[NATConfig], explicitIp: IpAddress): T =
  NATConfig(mode: ExplicitIp, explicitIp: explicitIp)

proc new*(
    T: typedesc[NATService], config: NATConfig, portMapper: NATPortMapper = nil
): T =
  ## Optional ``portMapper`` overrides the default backend. When ``nil`` and
  ## ``config.mode`` is ``Upnp``/``NatPmp``, setup builds the production mapper.
  T(config: config, portMapper: portMapper)

proc acquireMappings(
    self: NATService, listenAddrs: seq[MultiAddress]
): Result[void, string] =
  ## Discover the external IP and request a mapping per listen address.
  ## Populates ``externalIp``/``activeMappings``. Safe to call repeatedly.
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
  debug "Setting up NATService", mode = self.config.mode

  case self.config.mode
  of Auto:
    # TODO: wire autonat / hole-punching in here.
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

proc refreshLoop(
    self: NATService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  let interval =
    if self.config.refreshInterval > 0.seconds:
      self.config.refreshInterval
    else:
      DefaultNATRefreshInterval
  heartbeat "nat refresh", interval, sleepFirst = true:
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

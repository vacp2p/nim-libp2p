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
    natModeAuto
      ## Use libp2p-native mechanisms (autonat / hole-punching). No port-mapping
      ## is performed.
      ## TODO: In this skeleton it is a no-op;
    natModeExplicitIp
      ## Static external IP, no probing. The configured ``explicitIp`` is combined
      ## with the bound listen addresses to produce the announced address set.
    natModeUpnp
      ## Request port mappings from an UPnP-capable Internet Gateway Device via
      ## the SSDP/UPnP-IGD protocol. The mapper periodically renews the lease
      ## and deletes the mapping on shutdown.
    natModeNatPmp
      ## Request port mappings via NAT-PMP (RFC 6886). Same lifecycle as
      ## ``natModeUpnp``, but talks to the default gateway directly.

  NATConfig* = object
    case mode*: NATMode
    of natModeAuto:
      discard
    of natModeExplicitIp:
      explicitIp*: IpAddress
    of natModeUpnp, natModeNatPmp:
      description*: string
        ## Human-readable label registered with the gateway for the mapping
        ## (UPnP IGDs surface this in their admin UI).
      refreshInterval*: Duration
        ## How often we re-request the mapping. Must be strictly less than
        ## ``leaseDuration``, otherwise the lease expires before we renew.
      leaseDuration*: Duration
        ## Lease lifetime requested from the gateway. ``0.seconds`` asks UPnP
        ## for an infinite lease (NAT-PMP requires a positive lifetime).

  NATService* = ref object of Service
    config: NATConfig
    addressMapper: AddressMapper
    mapperFactory: NATPortMapperFactory
    portMapper: NATPortMapper
    externalIp: Opt[IpAddress]
    activeMappings: seq[PortMapping]
    refreshFut: Future[void]

const
  DefaultUpnpRefreshInterval* = 20.minutes
  DefaultUpnpLeaseDuration* = 60.minutes
  DefaultNATDescription* = "nim-libp2p"

proc upnpConfig*(
    description = DefaultNATDescription,
    refreshInterval = DefaultUpnpRefreshInterval,
    leaseDuration = DefaultUpnpLeaseDuration,
): NATConfig =
  NATConfig(
    mode: natModeUpnp,
    description: description,
    refreshInterval: refreshInterval,
    leaseDuration: leaseDuration,
  )

proc natPmpConfig*(
    description = DefaultNATDescription,
    refreshInterval = DefaultUpnpRefreshInterval,
    leaseDuration = DefaultUpnpLeaseDuration,
): NATConfig =
  NATConfig(
    mode: natModeNatPmp,
    description: description,
    refreshInterval: refreshInterval,
    leaseDuration: leaseDuration,
  )

proc new*(
    T: typedesc[NATService],
    config: NATConfig,
    mapperFactory: NATPortMapperFactory = nil,
): T =
  ## ``mapperFactory`` is used by tests to inject a fake port-mapper. When
  ## ``nil`` and ``config.mode`` is ``natModeUpnp``/``natModeNatPmp``, the
  ## service builds the production miniupnpc/libnatpmp-backed mapper at
  ## setup time.
  T(config: config, mapperFactory: mapperFactory)

proc acquireMappings(
    self: NATService, listenAddrs: seq[MultiAddress]
): Result[void, string] =
  ## Runs the (blocking) discovery + mapping calls against ``self.portMapper``
  ## using ``listenAddrs``. On success, populates ``self.externalIp`` and
  ## ``self.activeMappings``. Safe to call multiple times — refresh ticks
  ## reuse it. Callers pass the currently bound listen addresses; this proc
  ## does not reach into ``Switch`` because the initial mapping runs from the
  ## address mapper, where the bound listen set is the function argument.
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
  self.externalIp = Opt.some(extIp)
  self.activeMappings = acquired
  ok()

method setup*(self: NATService, switch: Switch) {.raises: [ServiceSetupError].} =
  debug "Setting up NATService", mode = self.config.mode

  case self.config.mode
  of natModeAuto:
    # TODO: wire autonat / hole-punching in here.
    discard
  of natModeExplicitIp:
    self.addressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      return explicitIpMapped(listenAddrs, self.config.explicitIp)
  of natModeUpnp, natModeNatPmp:
    if self.mapperFactory == nil:
      self.mapperFactory =
        case self.config.mode
        of natModeUpnp: newMiniupnpcMapper
        of natModeNatPmp: newNatPmpMapper
        else: nil
    try:
      self.portMapper = self.mapperFactory()
    except NATMapperError as e:
      raise newException(ServiceSetupError, "NAT mapper factory failed: " & e.msg)
    self.addressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      # First invocation runs while Switch.start is finishing — at that point
      # transports have bound and ``listenAddrs`` carries real ports, so this
      # is where we actually request the mapping from the gateway.
      if self.externalIp.isNone:
        self.acquireMappings(listenAddrs).isOkOr:
          warn "NAT initial mapping failed", error = error
          return @[]
      let extIp = self.externalIp.valueOr:
        return @[]
      return mappedAnnouncements(listenAddrs, extIp, self.activeMappings)

proc refreshLoop(self: NATService, switch: Switch) {.async: (raises: []).} =
  let interval =
    if self.config.refreshInterval > 0.seconds:
      self.config.refreshInterval
    else:
      DefaultUpnpRefreshInterval
  try:
    heartbeat "nat refresh", interval, sleepFirst = true:
      self.acquireMappings(switch.peerInfo.listenAddrs).isOkOr:
        warn "NAT mapping refresh failed", error = error
        continue
      try:
        await switch.peerInfo.update()
      except CancelledError:
        return
  except CancelledError:
    return

method start*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Starting NATService", mode = self.config.mode
  if self.addressMapper != nil:
    switch.peerInfo.addressMappers.add(self.addressMapper)
  case self.config.mode
  of natModeUpnp, natModeNatPmp:
    # Initial mapping acquisition is deferred to the addressMapper, which is
    # invoked by Switch.start after transports have bound (``peerInfo.update``
    # at the tail of ``Switch.start``). The refresh loop only re-acquires
    # afterwards, so its first tick must sleep before doing any work.
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
  # Do not touch peerInfo.announcedAddrs here: those may have been set by the
  # user via withAnnouncedAddresses, and triggering peerInfo.update during
  # shutdown can cause observers (e.g. IdentifyPusher) to broadcast while the
  # switch is tearing down.

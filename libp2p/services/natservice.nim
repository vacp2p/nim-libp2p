# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sequtils]
import chronos, chronicles, results
import ../[multiaddress, multicodec, wire]
import ../switch
import ./nat/[portmapper, upnp_mapper, natpmp_mapper]

export portmapper

logScope:
  topics = "libp2p natservice"

type
  NATMode* = enum
    Auto
      ## Use libp2p-native mechanisms (autonat / hole-punching). No port-mapping
      ## is performed here.
      ## TODO: In this skeleton it is a no-op; folded in by piece 3a.
    ExplicitIp
      ## Static external IP, no probing. The configured ``explicitIp`` is combined
      ## with the bound listen addresses to produce the announced address set.
    Upnp
      ## Discover an IGD via UPnP, request port mappings for each private
      ## listen address, and surface the public ``(extIp, extPort)`` multiaddrs
      ## through the peerInfo addressMappers chain. Mappings are refreshed
      ## periodically.
    NatPmp ## Same as ``Upnp`` but using the NAT-PMP protocol.

  NATConfig* = object
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
    addressMapper: AddressMapper
    portMapperFactory: PortMapperFactory
    mapper: PortMapper
    refreshLoopFut: Future[void]
    mappedPorts: seq[(Port, MapProto)]
    externalIp*: Opt[IpAddress]

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
    else:
      Opt.none(PortMapper)
  except ResourceExhaustedError as exc:
    error "Failed to construct port mapper", mode, err = exc.msg
    Opt.none(PortMapper)

proc new*(
    T: typedesc[NATService],
    config: NATConfig,
    portMapperFactory: PortMapperFactory = nil,
): T =
  T(config: config, portMapperFactory: portMapperFactory)

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

# --------------------------------------------------------------------------
# UPnP / NAT-PMP helpers
# --------------------------------------------------------------------------

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
): Future[bool] {.async: (raises: [CancelledError]).} =
  let discoverRes = await self.mapper.discover(self.config.discoveryTimeout)
  if discoverRes.isErr:
    warn "NAT discovery failed; not announcing mapped addresses",
      err = discoverRes.error
    self.externalIp = Opt.none(IpAddress)
    return false
  self.externalIp = Opt.some(discoverRes.get())
  info "NAT discovery succeeded", externalIp = self.externalIp.get()
  true

proc mapOnePort(
    self: NATService, lp: ListenPort, externalIp: IpAddress
): Future[Opt[MultiAddress]] {.async: (raises: [CancelledError]).} =
  let lease = uint32(self.config.leaseDuration.seconds)
  let mapRes = await self.mapper.map(lp.port, lp.port, lp.proto, lease)
  if mapRes.isErr:
    warn "NAT port mapping failed", port = lp.port, proto = lp.proto, err = mapRes.error
    return Opt.none(MultiAddress)

  let extPort = mapRes.get()
  let entry = (extPort, lp.proto)
  if entry notin self.mappedPorts:
    self.mappedPorts.add(entry)
  buildAnnouncedAddr(lp.multiAddr, externalIp, extPort)

proc unmapAll(self: NATService) {.async: (raises: [CancelledError]).} =
  for (port, proto) in self.mappedPorts:
    let r = await self.mapper.unmap(port, proto)
    if r.isErr:
      warn "Failed to unmap port", port, proto, err = r.error
  self.mappedPorts.setLen(0)

proc setupMappings*(
    self: NATService, listenAddrs: seq[MultiAddress]
): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
  ## Discover the IGD if needed and request a mapping for every private listen
  ## address; updates ``externalIp`` and ``mappedPorts`` as a side-effect.
  let listenPorts = findMappableListenPorts(listenAddrs)
  if listenPorts.len == 0:
    debug "No private listen addresses to map; skipping NAT port mapping"
    return @[]
  if self.mapper.isNil:
    debug "No port mapper available; skipping NAT port mapping"
    return @[]
  if self.externalIp.isNone and not await self.discoverExternalIp():
    return @[]

  let externalIp = self.externalIp.get()
  var announced: seq[MultiAddress]
  for lp in listenPorts:
    (await self.mapOnePort(lp, externalIp)).withValue(annAddr):
      if annAddr notin announced:
        announced.add(annAddr)
  announced

proc refreshLoop(
    self: NATService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  ## Trigger ``peerInfo.update()`` periodically so the addressMapper re-runs
  ## and reissues mappings before the lease expires. Invalidates the cached
  ## external IP first so DHCP renewals / failovers are picked up.
  while true:
    await sleepAsync(self.config.refreshInterval)
    self.externalIp = Opt.none(IpAddress)
    await switch.peerInfo.update()

# --------------------------------------------------------------------------
# Service lifecycle
# --------------------------------------------------------------------------

method setup*(self: NATService, switch: Switch) {.raises: [ServiceSetupError].} =
  debug "Setting up NATService", mode = self.config.mode

  case self.config.mode
  of Auto, ExplicitIp:
    discard
  of Upnp, NatPmp:
    if self.config.refreshInterval <= 0.seconds:
      raise newException(
        ServiceSetupError,
        "NATService: refreshInterval must be > 0; use upnpConfig/natPmpConfig",
      )
    if self.config.discoveryTimeout <= 0.seconds:
      raise newException(
        ServiceSetupError,
        "NATService: discoveryTimeout must be > 0; use upnpConfig/natPmpConfig",
      )
    if self.config.leaseDuration <= 0.seconds:
      raise newException(
        ServiceSetupError,
        "NATService: leaseDuration must be > 0; use upnpConfig/natPmpConfig",
      )

method start*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Starting NATService", mode = self.config.mode

  # Construct the mapper and addressMapper here (not in setup) so a
  # stop()/start() cycle re-creates them after we tear them down in stop().
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

  if self.addressMapper != nil:
    switch.peerInfo.addressMappers.add(self.addressMapper)
  # peerInfo.update is invoked by Switch.start once transports have bound, at
  # which point the mapper runs against the resolved listenAddrs.

method stop*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Stopping NATService"

  case self.config.mode
  of Auto:
    discard
  of ExplicitIp:
    if self.addressMapper != nil:
      switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
      self.addressMapper = nil
    # Do not touch peerInfo.announcedAddrs here: those may have been set by the
    # user via withAnnouncedAddresses, and triggering peerInfo.update during
    # shutdown can cause observers (e.g. IdentifyPusher) to broadcast while the
    # switch is tearing down.
  of Upnp, NatPmp:
    if self.refreshLoopFut != nil:
      await self.refreshLoopFut.cancelAndWait()
      self.refreshLoopFut = nil
    if self.addressMapper != nil:
      switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
      self.addressMapper = nil
    if self.mapper != nil:
      await self.unmapAll()
      self.mapper.close()
      self.mapper = nil
    self.externalIp = Opt.none(IpAddress)
    # Mirror the explicitIp path: deliberately do not call peerInfo.update()
    # during shutdown.

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
      leaseDuration*: uint32

  PortMapperFactory* = proc(mode: NATMode): PortMapper {.gcsafe, raises: [].}

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
  DefaultLeaseDuration*: uint32 = 3600

proc defaultPortMapperFactory(mode: NATMode): PortMapper {.gcsafe, raises: [].} =
  try:
    case mode
    of Upnp:
      newUpnpMapper()
    of NatPmp:
      newNatPmpMapper()
    else:
      nil
  except ResourceExhaustedError as exc:
    error "Failed to construct port mapper", mode, err = exc.msg
    nil

proc new*(
    T: typedesc[NATService],
    config: NATConfig,
    portMapperFactory: PortMapperFactory = defaultPortMapperFactory,
): T =
  T(config: config, portMapperFactory: portMapperFactory)

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
      discard res.append(portMa)
    else:
      discard res.append(part)
  Opt.some(res)

proc extractListenPort(ma: MultiAddress): Opt[ListenPort] =
  let ta = initTAddress(ma).valueOr:
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

proc ensureDiscovered(
    self: NATService
): Future[bool] {.async: (raises: [CancelledError]).} =
  if self.externalIp.isSome:
    return true
  let discoverRes = await self.mapper.discover(self.config.discoveryTimeout)
  if discoverRes.isErr:
    warn "NAT discovery failed; not announcing mapped addresses",
      err = discoverRes.error
    return false
  self.externalIp = Opt.some(discoverRes.get())
  info "NAT discovery succeeded", externalIp = self.externalIp.get()
  true

proc mapOnePort(
    self: NATService, lp: ListenPort, externalIp: IpAddress
): Future[Opt[MultiAddress]] {.async: (raises: [CancelledError]).} =
  let mapRes =
    await self.mapper.map(lp.port, lp.port, lp.proto, self.config.leaseDuration)
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
  if not await self.ensureDiscovered():
    return @[]

  let externalIp = self.externalIp.get()
  var announced: seq[MultiAddress]
  for lp in listenPorts:
    (await self.mapOnePort(lp, externalIp)).withValue(annAddr):
      if annAddr notin announced:
        announced.add(annAddr)
  announced

proc refreshLoop(self: NATService, switch: Switch) {.async: (raises: []).} =
  ## Trigger ``peerInfo.update()`` periodically so the addressMapper re-runs
  ## and reissues mappings before the lease expires.
  while true:
    try:
      await sleepAsync(self.config.refreshInterval)
    except CancelledError:
      return

    try:
      await switch.peerInfo.update()
    except CancelledError:
      return

# --------------------------------------------------------------------------
# Service lifecycle
# --------------------------------------------------------------------------

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
    if self.portMapperFactory.isNil:
      raise newException(
        ServiceSetupError, "NATService: portMapperFactory must be set for UPnP/NAT-PMP"
      )
    self.mapper = self.portMapperFactory(self.config.mode)
    if self.mapper.isNil:
      raise newException(
        ServiceSetupError,
        "NATService: portMapperFactory returned nil for " & $self.config.mode,
      )
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

method start*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Starting NATService", mode = self.config.mode

  if self.addressMapper != nil:
    switch.peerInfo.addressMappers.add(self.addressMapper)
  # peerInfo.update is invoked by Switch.start once transports have bound, at
  # which point the mapper runs against the resolved listenAddrs.

  case self.config.mode
  of Upnp, NatPmp:
    self.refreshLoopFut = self.refreshLoop(switch)
  else:
    discard

method stop*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Stopping NATService"

  case self.config.mode
  of Auto:
    discard
  of ExplicitIp:
    if self.addressMapper != nil:
      switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
    # Do not touch peerInfo.announcedAddrs here: those may have been set by the
    # user via withAnnouncedAddresses, and triggering peerInfo.update during
    # shutdown can cause observers (e.g. IdentifyPusher) to broadcast while the
    # switch is tearing down.
  of Upnp, NatPmp:
    if self.refreshLoopFut != nil and not self.refreshLoopFut.finished:
      await self.refreshLoopFut.cancelAndWait()
    if self.addressMapper != nil:
      switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
    if self.mapper != nil:
      await self.unmapAll()
      self.mapper.close()
      self.mapper = nil
    # Mirror the explicitIp path: deliberately do not call peerInfo.update()
    # during shutdown.

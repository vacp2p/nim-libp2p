# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sequtils, strutils]
import chronos, chronicles, results
import ../[multiaddress, multicodec, wire]
import ../switch
import ./nat/[portmapper, upnp_mapper, natpmp_mapper]

export portmapper

logScope:
  topics = "libp2p natservice"

type
  NATMode* = enum
    natModeAuto
      ## Use libp2p-native mechanisms (autonat / hole-punching). No port-mapping
      ## is performed here.
      ## TODO: In this skeleton it is a no-op; folded in by piece 3a.
    natModeExplicitIp
      ## Static external IP, no probing. The configured ``explicitIp`` is combined
      ## with the bound listen addresses to produce the announced address set.
    natModeUpnp
      ## Discover an IGD via UPnP, request port mappings for each private
      ## listen address, and surface the public ``(extIp, extPort)`` multiaddrs
      ## through the peerInfo addressMappers chain. Mappings are refreshed
      ## periodically.
    natModeNatPmp ## Same as ``natModeUpnp`` but using the NAT-PMP protocol.

  NATConfig* = object
    case mode*: NATMode
    of natModeExplicitIp:
      explicitIp*: IpAddress
    of natModeAuto:
      discard
    of natModeUpnp, natModeNatPmp:
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
  DefaultUpnpRefreshInterval* = 30.minutes
  DefaultUpnpDiscoveryTimeout* = 10.seconds
  DefaultUpnpLeaseDuration*: uint32 = 3600

proc upnpConfig*(
    refreshInterval = DefaultUpnpRefreshInterval,
    discoveryTimeout = DefaultUpnpDiscoveryTimeout,
    leaseDuration = DefaultUpnpLeaseDuration,
): NATConfig =
  NATConfig(
    mode: natModeUpnp,
    refreshInterval: refreshInterval,
    discoveryTimeout: discoveryTimeout,
    leaseDuration: leaseDuration,
  )

proc natPmpConfig*(
    refreshInterval = DefaultUpnpRefreshInterval,
    discoveryTimeout = DefaultUpnpDiscoveryTimeout,
    leaseDuration = DefaultUpnpLeaseDuration,
): NATConfig =
  NATConfig(
    mode: natModeNatPmp,
    refreshInterval: refreshInterval,
    discoveryTimeout: discoveryTimeout,
    leaseDuration: leaseDuration,
  )

proc defaultPortMapperFactory(mode: NATMode): PortMapper {.gcsafe, raises: [].} =
  try:
    case mode
    of natModeUpnp:
      newUpnpMapper()
    of natModeNatPmp:
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

proc extractListenPort(ma: MultiAddress): Opt[ListenPort] =
  ## Pulls (port, transport protocol) out of a listen multiaddress. Returns
  ## ``none`` if ``ma`` lacks an IP4/IP6 part or a TCP/UDP part. Only IPv4 is
  ## considered — UPnP and NAT-PMP are IPv4 protocols.
  if ma.getIp().isNone:
    return Opt.none(ListenPort)

  let tcpPart = ma[multiCodec("tcp")]
  if tcpPart.isOk:
    let ta = initTAddress(ma).valueOr:
      return Opt.none(ListenPort)
    return Opt.some((port: ta.port, proto: mpTcp, multiAddr: ma))

  let udpPart = ma[multiCodec("udp")]
  if udpPart.isOk:
    let ta = initTAddress(ma).valueOr:
      return Opt.none(ListenPort)
    return Opt.some((port: ta.port, proto: mpUdp, multiAddr: ma))

  Opt.none(ListenPort)

proc buildAnnouncedAddr(
    listenAddr: MultiAddress, externalIp: IpAddress, externalPort: Port
): Opt[MultiAddress] =
  ## Take a private listen multiaddress and return the announced equivalent
  ## with ``externalIp``/``externalPort`` substituted in, preserving transport
  ## and any suffix.
  if externalIp.family != IpAddressFamily.IPv4:
    return Opt.none(MultiAddress)

  let replaced = listenAddr.replaceIp(externalIp).valueOr:
    return Opt.none(MultiAddress)

  # If the source listen port differs from the mapped external port, we have
  # to overwrite the port component too. Build by string for simplicity.
  let srcTa = initTAddress(listenAddr).valueOr:
    return Opt.some(replaced)
  if srcTa.port == externalPort:
    return Opt.some(replaced)

  # Rebuild via string substitution: replace "/tcp/<srcPort>" or "/udp/<srcPort>".
  let s = $replaced
  let srcPortStr = "/" & $srcTa.port
  let srcTcp = "/tcp" & srcPortStr
  let srcUdp = "/udp" & srcPortStr
  let dstTcp = "/tcp/" & $externalPort
  let dstUdp = "/udp/" & $externalPort

  let rebuilt =
    if srcTcp in s:
      s.replace(srcTcp, dstTcp)
    elif srcUdp in s:
      s.replace(srcUdp, dstUdp)
    else:
      return Opt.some(replaced)

  let m = MultiAddress.init(rebuilt).valueOr:
    return Opt.some(replaced)
  Opt.some(m)

proc unmapAll(self: NATService) {.async: (raises: [CancelledError]).} =
  ## Tear down any port mappings we created. Best-effort — failures are logged
  ## but don't propagate.
  for (port, proto) in self.mappedPorts:
    let r = await self.mapper.unmap(port, proto)
    if r.isErr:
      warn "Failed to unmap port", port, proto, err = r.error
  self.mappedPorts.setLen(0)

proc setupMappings*(
    self: NATService, listenAddrs: seq[MultiAddress]
): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
  ## Discover the IGD if not already done, request a mapping for every private
  ## listen address, and return the resulting announced multiaddr set. Updates
  ## ``self.externalIp`` and ``self.mappedPorts`` as a side-effect. Exposed for
  ## tests; the production caller is the addressMapper closure installed in
  ## ``setup``.
  let listenPorts: seq[ListenPort] = listenAddrs
    .filterIt(it.isPrivateMA)
    .mapIt(extractListenPort(it))
    .filterIt(it.isSome)
    .mapIt(it.get())

  if listenPorts.len == 0:
    debug "No private listen addresses to map; skipping NAT port mapping"
    return @[]

  if self.mapper.isNil:
    debug "No port mapper available; skipping NAT port mapping"
    return @[]

  if self.externalIp.isNone:
    let discoverRes = await self.mapper.discover(self.config.discoveryTimeout)
    if discoverRes.isErr:
      warn "NAT discovery failed; not announcing mapped addresses",
        err = discoverRes.error
      return @[]
    self.externalIp = Opt.some(discoverRes.get())
    info "NAT discovery succeeded", externalIp = self.externalIp.get()

  let externalIp = self.externalIp.get()

  var announced: seq[MultiAddress]
  for lp in listenPorts:
    let mapRes =
      await self.mapper.map(lp.port, lp.port, lp.proto, self.config.leaseDuration)
    if mapRes.isErr:
      warn "NAT port mapping failed",
        port = lp.port, proto = lp.proto, err = mapRes.error
      continue

    let extPort = mapRes.get()
    let entry = (extPort, lp.proto)
    if entry notin self.mappedPorts:
      self.mappedPorts.add(entry)

    buildAnnouncedAddr(lp.multiAddr, externalIp, extPort).withValue(annAddr):
      if annAddr notin announced:
        announced.add(annAddr)

  announced

proc refreshLoop(self: NATService, switch: Switch) {.async: (raises: []).} =
  ## Re-issue the mapping requests before the lease expires by triggering a
  ## ``peerInfo.update()``, which re-invokes our addressMapper.
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
  of natModeAuto:
    # TODO: wire autonat / hole-punching in here.
    discard
  of natModeExplicitIp:
    self.addressMapper = proc(
        listenAddrs: seq[MultiAddress]
    ): Future[seq[MultiAddress]] {.async: (raises: [CancelledError]).} =
      return explicitIpMapped(listenAddrs, self.config.explicitIp)
  of natModeUpnp, natModeNatPmp:
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
  of natModeUpnp, natModeNatPmp:
    self.refreshLoopFut = self.refreshLoop(switch)
  else:
    discard

method stop*(self: NATService, switch: Switch) {.async: (raises: [CancelledError]).} =
  trace "Stopping NATService"

  case self.config.mode
  of natModeAuto:
    discard
  of natModeExplicitIp:
    if self.addressMapper != nil:
      switch.peerInfo.addressMappers.keepItIf(it != self.addressMapper)
    # Do not touch peerInfo.announcedAddrs here: those may have been set by the
    # user via withAnnouncedAddresses, and triggering peerInfo.update during
    # shutdown can cause observers (e.g. IdentifyPusher) to broadcast while the
    # switch is tearing down.
  of natModeUpnp, natModeNatPmp:
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

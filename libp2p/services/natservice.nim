# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sequtils]
import chronos, chronicles, results
import nat_traversal/[miniupnpc, natpmp]
import ../[multiaddress, multicodec]
import ../utils/heartbeat
import ../switch

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

  NATProtocol* = enum
    NATProtoTcp = "TCP"
    NATProtoUdp = "UDP"

  PortMapping* = object
    internalPort*: Port
    externalPort*: Port
    protocol*: NATProtocol

  NATMapperError* = object of CatchableError

  NATPortMapper* = ref object of RootObj
    ## Abstract backend that wraps a single port-mapping protocol (UPnP or
    ## NAT-PMP). Subclassed for production (miniupnpc / libnatpmp) and for
    ## tests (in-memory fakes). Method bodies block the calling thread and
    ## must not be invoked on the chronos event loop without yielding —
    ## see ``runDiscovery``/``runMapping`` in ``NATService`` below.

  NATPortMapperFactory* = proc(): NATPortMapper {.gcsafe, raises: [NATMapperError].}

  NATService* = ref object of Service
    config: NATConfig
    addressMapper: AddressMapper
    mapperFactory: NATPortMapperFactory
    portMapper: NATPortMapper
    externalIp: Opt[IpAddress]
    activeMappings: seq[PortMapping]
    refreshFut: Future[void]

method discoverExternalIp*(
    m: NATPortMapper
): Result[IpAddress, string] {.base, gcsafe, raises: [].} =
  raiseAssert "[NATPortMapper.discoverExternalIp] abstract method not implemented"

method addMapping*(
    m: NATPortMapper,
    internalPort: Port,
    protocol: NATProtocol,
    leaseDuration: Duration,
    description: string,
): Result[Port, string] {.base, gcsafe, raises: [].} =
  raiseAssert "[NATPortMapper.addMapping] abstract method not implemented"

method deleteMapping*(
    m: NATPortMapper, externalPort: Port, internalPort: Port, protocol: NATProtocol
): Result[void, string] {.base, gcsafe, raises: [].} =
  raiseAssert "[NATPortMapper.deleteMapping] abstract method not implemented"

method close*(m: NATPortMapper) {.base, gcsafe, raises: [].} =
  discard

# ---------------------------------------------------------------------------
# Miniupnpc-backed mapper
# ---------------------------------------------------------------------------

type MiniupnpcMapper* = ref object of NATPortMapper
  upnp: Miniupnp
  discovered: bool

proc newMiniupnpcMapper*(): NATPortMapper {.raises: [NATMapperError].} =
  let m = MiniupnpcMapper(upnp: newMiniupnp())
  m.upnp.discoverDelay = 200
  m

proc ensureDiscovered(self: MiniupnpcMapper): Result[void, string] =
  if self.discovered:
    return ok()
  self.upnp.discover().isOkOr:
    return err($error)
  case self.upnp.selectIGD()
  of IGDNotFound:
    return err("UPnP: Internet Gateway Device not found")
  of NotAnIGD:
    return err("UPnP: device found is not an IGD")
  of IGDFound, IGDIpNotRoutable, IGDNotConnected:
    # NotRoutable/NotConnected are best-effort — the gateway may still accept
    # the mapping. Match the behaviour in nim-eth's nat.nim.
    self.discovered = true
    ok()

method discoverExternalIp*(self: MiniupnpcMapper): Result[IpAddress, string] =
  ?self.ensureDiscovered()
  let ipStr = self.upnp.externalIPAddress().valueOr:
    return err($error)
  try:
    ok(parseIpAddress(ipStr))
  except ValueError as e:
    err("UPnP: unparsable external IP '" & ipStr & "': " & e.msg)

method addMapping*(
    self: MiniupnpcMapper,
    internalPort: Port,
    protocol: NATProtocol,
    leaseDuration: Duration,
    description: string,
): Result[Port, string] =
  ?self.ensureDiscovered()
  let proto =
    case protocol
    of NATProtoTcp: UPNPProtocol.TCP
    of NATProtoUdp: UPNPProtocol.UDP
  let leaseSecs = leaseDuration.seconds
  self.upnp.addPortMapping(
    externalPort = $int(internalPort),
    protocol = proto,
    internalHost = self.upnp.lanAddr,
    internalPort = $int(internalPort),
    desc = description,
    leaseDuration = int(leaseSecs),
  ).isOkOr:
    return err($error)
  ok(internalPort)

method deleteMapping*(
    self: MiniupnpcMapper, externalPort: Port, internalPort: Port, protocol: NATProtocol
): Result[void, string] =
  if not self.discovered:
    return ok()
  let proto =
    case protocol
    of NATProtoTcp: UPNPProtocol.TCP
    of NATProtoUdp: UPNPProtocol.UDP
  self.upnp.deletePortMapping(externalPort = $int(externalPort), protocol = proto).isOkOr:
    return err($error)
  ok()

# ---------------------------------------------------------------------------
# NAT-PMP-backed mapper
# ---------------------------------------------------------------------------

type NatPmpMapper* = ref object of NATPortMapper
  npmp: NatPmp
  initialized: bool

proc newNatPmpMapper*(): NATPortMapper {.raises: [NATMapperError].} =
  NatPmpMapper(npmp: newNatPmp())

proc ensureInitialized(self: NatPmpMapper): Result[void, string] =
  if self.initialized:
    return ok()
  self.npmp.init().isOkOr:
    return err($error)
  self.initialized = true
  ok()

method discoverExternalIp*(self: NatPmpMapper): Result[IpAddress, string] =
  ?self.ensureInitialized()
  let ipStr = self.npmp.externalIPAddress().valueOr:
    return err(error)
  try:
    ok(parseIpAddress($ipStr))
  except ValueError as e:
    err("NAT-PMP: unparsable external IP '" & $ipStr & "': " & e.msg)

method addMapping*(
    self: NatPmpMapper,
    internalPort: Port,
    protocol: NATProtocol,
    leaseDuration: Duration,
    description: string,
): Result[Port, string] =
  ?self.ensureInitialized()
  let proto =
    case protocol
    of NATProtoTcp: NatPmpProtocol.TCP
    of NATProtoUdp: NatPmpProtocol.UDP
  let extPort = self.npmp.addPortMapping(
    eport = cushort(internalPort),
    iport = cushort(internalPort),
    protocol = proto,
    lifetime = culong(leaseDuration.seconds),
  ).valueOr:
    return err(error)
  ok(Port(extPort))

method deleteMapping*(
    self: NatPmpMapper, externalPort: Port, internalPort: Port, protocol: NATProtocol
): Result[void, string] =
  if not self.initialized:
    return ok()
  let proto =
    case protocol
    of NATProtoTcp: NatPmpProtocol.TCP
    of NATProtoUdp: NatPmpProtocol.UDP
  self.npmp.deletePortMapping(
    eport = cushort(externalPort), iport = cushort(internalPort), protocol = proto
  ).isOkOr:
    return err(error)
  ok()

# ---------------------------------------------------------------------------
# NATService
# ---------------------------------------------------------------------------

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

proc extractPort(
    ma: MultiAddress
): tuple[port: Port, protocol: NATProtocol, present: bool] =
  ## Walk the multiaddress and return the first /tcp or /udp port + protocol.
  ## The /quic, /quic-v1 etc. suffixes (which sit *after* /udp in the address)
  ## do not affect what we map: NAT-PMP/UPnP only know about TCP/UDP.
  let tcpCodec = multiCodec("tcp")
  let udpCodec = multiCodec("udp")
  for part in ma.items:
    let p = part.valueOr:
      continue
    let code = p.protoCode().valueOr:
      continue
    if code == tcpCodec or code == udpCodec:
      let portBytes = p.protoArgument().valueOr:
        continue
      if portBytes.len != 2:
        continue
      let port = Port((uint16(portBytes[0]) shl 8) or uint16(portBytes[1]))
      let proto = if code == tcpCodec: NATProtoTcp else: NATProtoUdp
      return (port, proto, true)
  (Port(0), NATProtoTcp, false)

proc mappedAnnouncements*(
    listenAddrs: seq[MultiAddress], externalIp: IpAddress, mappings: seq[PortMapping]
): seq[MultiAddress] =
  ## For each listen address, find a matching ``PortMapping`` (by internal
  ## port + protocol) and emit a multiaddr with the IP swapped to
  ## ``externalIp`` and the port swapped to ``mapping.externalPort``. Listen
  ## addresses without an IP component or without a matching mapping are
  ## dropped. Duplicates are collapsed.
  var announces: seq[MultiAddress]
  for listenAddr in listenAddrs:
    let
      (internalPort, proto, present) = extractPort(listenAddr)
      ip = listenAddr.getIp().valueOr:
        continue
    if not present:
      continue
    if ip.family != externalIp.family:
      continue
    var matched: Opt[PortMapping]
    for m in mappings:
      if m.internalPort == internalPort and m.protocol == proto:
        matched = Opt.some(m)
        break
    let mapping = matched.valueOr:
      continue
    # Build the announced address: swap the IP component and the tcp/udp port.
    let
      ip4 = multiCodec("ip4")
      ip6 = multiCodec("ip6")
      newIpMa =
        case externalIp.family
        of IpAddressFamily.IPv4:
          MultiAddress.init(ip4, externalIp.address_v4).valueOr:
            continue
        of IpAddressFamily.IPv6:
          MultiAddress.init(ip6, externalIp.address_v6).valueOr:
            continue
      portCodec =
        if proto == NATProtoTcp:
          multiCodec("tcp")
        else:
          multiCodec("udp")
      newPortMa = MultiAddress.init(portCodec, int(mapping.externalPort)).valueOr:
        continue
    var rebuilt = MultiAddress.init()
    var replacedIp = false
    var replacedPort = false
    var appendOk = true
    for part in listenAddr.items:
      let p = part.valueOr:
        appendOk = false
        break
      let code = p.protoCode().valueOr:
        appendOk = false
        break
      if not replacedIp and (code == ip4 or code == ip6):
        if rebuilt.append(newIpMa).isErr:
          appendOk = false
          break
        replacedIp = true
      elif not replacedPort and (code == multiCodec("tcp") or code == multiCodec("udp")):
        if rebuilt.append(newPortMa).isErr:
          appendOk = false
          break
        replacedPort = true
      else:
        if rebuilt.append(p).isErr:
          appendOk = false
          break
    if not appendOk or not replacedIp or not replacedPort:
      continue
    if rebuilt notin announces:
      announces.add(rebuilt)
  announces

proc collectInternalPorts(listenAddrs: seq[MultiAddress]): seq[PortMapping] =
  ## Deduplicate (port, protocol) pairs across all listen addresses, with the
  ## external port initially set equal to the internal port. The external port
  ## is updated by the gateway response in ``acquireMappings``.
  var seen: seq[PortMapping]
  for listenAddr in listenAddrs:
    let (port, proto, present) = extractPort(listenAddr)
    if not present:
      continue
    let candidate = PortMapping(internalPort: port, externalPort: port, protocol: proto)
    var dup = false
    for m in seen:
      if m.internalPort == port and m.protocol == proto:
        dup = true
        break
    if not dup:
      seen.add(candidate)
  seen

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

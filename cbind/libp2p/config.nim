# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Config crossing the FFI boundary and its parsing, `include`d into
## `../libp2p.nim`.
##
## `Libp2pConfig` is the raw, wire-friendly shape the host fills in; `parse`
## validates it once and returns a `ParsedConfig` of ready-to-use Nim values, so
## the node builder never touches a raw string or ordinal again:
##
##   let cfg = ?config.parse()
##   ... cfg.privKey, cfg.transport, cfg.bootstrapNodes ...
##
## The `{.ffi.}` types share this module with `genBindings()` on purpose: nim-ffi
## reads the object fields straight from the AST, and an exported field would
## leak its `*` into the generated field name. `include` (not `import`) keeps the
## fields unexported and the emitted bindings clean.

type TransportType {.ffi.} = enum
  Quic = "quic"
  Tcp = "tcp"

type MuxerType {.ffi.} = enum
  Mplex = "mplex"
  Yamux = "yamux"

type BootstrapNode {.ffi.} = object
  peerId: string
  multiaddrs: seq[string]

type Libp2pConfig {.ffi.} = object
  mountGossipsub: bool
    ## Mount GossipSub for publishing and receiving messages via pubsub.
  gossipsubTriggerSelf: bool ## Deliver locally published GossipSub messages to self.
  mountKad: bool ## Mount the Kademlia DHT service.
  mountServiceDiscovery: bool ## Mount random-find based service discovery.
  dnsResolver: string ## DNS server address; empty uses the core defaults.
  addrs: seq[string] ## Listen multiaddresses for the switch.
  muxer: MuxerType ## Type of muxer used for TCP transports.
  transport: TransportType ## Type of transport for selecting TCP or QUIC.
  bootstrapNodes: seq[BootstrapNode]
    ## Peers to add to the peer store and Kad bootstrap set.
  privKey: seq[byte] ## Serialized private key; empty generates a fresh key.
  maxConnections: int
    ## Connection manager total limit; non-positive uses the core default.
  maxIn: int ## Incoming connection limit; non-positive uses the core default.
  maxOut: int ## Outgoing connection limit; non-positive uses the core default.
  maxConnsPerPeer: int ## Per-peer connection limit; non-positive uses the core default.
  circuitRelay: bool ## Mount the relay v2 server.
  circuitRelayClient: bool ## Enable the relay v2 client transport.
  autonat: bool ## Enable the legacy direct AutoNAT v1 service.
  autonatV2: bool ## Compatibility alias for NAT reachability probing with AutoNAT v2.
  autonatV2Server: bool ## Mount the AutoNAT v2 server.
  natPortMappingAuto: bool
    ## Enable gateway port mapping with automatic protocol selection.
  natPortMappingUpnp: bool ## Enable gateway port mapping restricted to UPnP-IGD.
  natPortMappingNatPmp: bool ## Enable gateway port mapping restricted to PCP/NAT-PMP.
  natExplicitIp: string
    ## Announce this external IP instead of discovering a gateway mapping.
  natDiscoveryTimeoutMs: int64
    ## Gateway discovery timeout for port mapping; <= 0 uses the core default.
  natMappingTimeoutMs: int64
    ## Gateway mapping request timeout; <= 0 uses the core default.
  natReachabilityV1: bool ## Enable NAT reachability probing with AutoNAT v1.
  natReachabilityV2: bool ## Enable NAT reachability probing with AutoNAT v2.
  natReachabilityScheduleIntervalMs: int64
    ## Reachability probe interval; <= 0 disables scheduling override.
  natHolePunching: bool ## Enable AutoNAT v1, AutoRelay, and DCUtR hole punching.
  natHolePunchingMaxNumRelays: int
    ## Relay reservation target for hole punching; <= 0 uses the core default.
  natHolePunchingScheduleIntervalMs: int64
    ## Hole-punch reachability probe interval; <= 0 disables scheduling override.

type ParsedTransport = object
  ## The transport to build, plus the muxer it needs. A muxer is only used with
  ## TCP, so the variant makes "no muxer for QUIC" unrepresentable rather than
  ## carrying a meaningless default.
  case kind: TransportType
  of TransportType.Tcp:
    muxer: MuxerType
  of TransportType.Quic:
    discard

type ParsedConfig = object
  ## `Libp2pConfig` with every field validated and decoded once. Consumed by the
  ## node builder; carries no raw strings or ordinals.
  dnsServers: seq[TransportAddress]
  addrs: seq[MultiAddress]
  transport: ParsedTransport
  privKey: Opt[PrivateKey]
  bootstrapNodes: seq[(PeerId, seq[MultiAddress])]
  maxConnections: int
  maxIn: int
  maxOut: int
  maxConnsPerPeer: int
  circuitRelay: bool
  circuitRelayClient: bool
  autonat: bool
  nat: Opt[NATConfig]
  autonatV2Server: bool
  mountGossipsub: bool
  gossipsubTriggerSelf: bool
  mountKad: bool
  mountServiceDiscovery: bool

proc parseMultiaddrs(raw: openArray[string]): Result[seq[MultiAddress], string] =
  var addrs: seq[MultiAddress]
  for a in raw:
    let ma = MultiAddress.init(a).valueOr:
      return err("invalid multiaddress '" & a & "': " & $error)
    addrs.add(ma)
  ok(addrs)

proc parseBootstrapNodes(
    nodes: openArray[BootstrapNode]
): Result[seq[(PeerId, seq[MultiAddress])], string] =
  var parsed: seq[(PeerId, seq[MultiAddress])]
  for node in nodes:
    let peerId = PeerId.init(node.peerId).valueOr:
      return err("invalid bootstrap peer id: " & $error)
    let addrs = ?parseMultiaddrs(node.multiaddrs)
    parsed.add((peerId, addrs))
  ok(parsed)

proc resolveDnsServers(dnsResolver: string): Result[seq[TransportAddress], string] =
  if dnsResolver.len == 0:
    return ok(DefaultDnsServers)
  try:
    ok(@[initTAddress(dnsResolver)])
  except TransportAddressError as e:
    err("invalid dnsResolver address: " & e.msg)

proc parsePrivateKey(raw: seq[byte]): Result[Opt[PrivateKey], string] =
  if raw.len == 0:
    return ok(Opt.none(PrivateKey))
  let key = PrivateKey.init(raw).valueOr:
    return err("invalid private key: " & $error)
  ok(Opt.some(key))

func parseTransportConfig(config: Libp2pConfig): ParsedTransport =
  # A muxer is only used with TCP, so a QUIC config's `muxer` is ignored.
  case config.transport
  of TransportType.Quic:
    ParsedTransport(kind: TransportType.Quic)
  of TransportType.Tcp:
    ParsedTransport(kind: TransportType.Tcp, muxer: config.muxer)

func countEnabled(values: varargs[bool]): int =
  for value in values:
    if value:
      result.inc

func optDurationMs(ms: int64): Opt[Duration] =
  if ms > 0:
    Opt.some(chronos.milliseconds(ms))
  else:
    Opt.none(Duration)

proc parseNATConfig(config: Libp2pConfig): Result[Opt[NATConfig], string] =
  let
    portMappingModes = countEnabled(
      config.natPortMappingAuto,
      config.natPortMappingUpnp,
      config.natPortMappingNatPmp,
      config.natExplicitIp.len > 0,
    )
    wantsReachabilityV1 = config.natReachabilityV1
    wantsReachabilityV2 = config.natReachabilityV2 or config.autonatV2
    wantsReachability = wantsReachabilityV1 or wantsReachabilityV2

  if portMappingModes > 1:
    return err("NAT port mapping modes are mutually exclusive")
  if wantsReachabilityV1 and wantsReachabilityV2:
    return err("NAT reachability v1 and v2 are mutually exclusive")
  if wantsReachability and config.natHolePunching:
    return err(
      "NAT hole punching and reachability are mutually exclusive; " &
        "hole punching already runs AutoNAT v1"
    )
  if config.natReachabilityScheduleIntervalMs > 0 and not wantsReachability:
    return err(
      "natReachabilityScheduleIntervalMs requires natReachabilityV1, " &
        "natReachabilityV2, or autonatV2"
    )
  if not config.natHolePunching:
    if config.natHolePunchingMaxNumRelays > 0:
      return err("natHolePunchingMaxNumRelays requires natHolePunching")
    if config.natHolePunchingScheduleIntervalMs > 0:
      return err("natHolePunchingScheduleIntervalMs requires natHolePunching")

  var nat = NATConfig()

  if portMappingModes == 1:
    let
      discoveryTimeout =
        if config.natDiscoveryTimeoutMs > 0:
          chronos.milliseconds(config.natDiscoveryTimeoutMs)
        else:
          DefaultDiscoveryTimeout
      mappingTimeout =
        if config.natMappingTimeoutMs > 0:
          chronos.milliseconds(config.natMappingTimeoutMs)
        else:
          DefaultMappingTimeout

    if config.natExplicitIp.len > 0:
      try:
        nat.portMapping = Opt.some(
          PortMappingConfig(
            mode: ExplicitIp, explicitIp: parseIpAddress(config.natExplicitIp)
          )
        )
      except ValueError as e:
        return err("invalid natExplicitIp: " & e.msg)
    elif config.natPortMappingUpnp:
      nat.portMapping = Opt.some(
        PortMappingConfig(
          mode: Upnp, discoveryTimeout: discoveryTimeout, mappingTimeout: mappingTimeout
        )
      )
    elif config.natPortMappingNatPmp:
      nat.portMapping = Opt.some(
        PortMappingConfig(
          mode: NatPmp,
          discoveryTimeout: discoveryTimeout,
          mappingTimeout: mappingTimeout,
        )
      )
    else:
      nat.portMapping = Opt.some(
        PortMappingConfig(
          mode: Auto, discoveryTimeout: discoveryTimeout, mappingTimeout: mappingTimeout
        )
      )

  if wantsReachability:
    let scheduleInterval = optDurationMs(config.natReachabilityScheduleIntervalMs)
    if wantsReachabilityV1:
      nat.reachability = Opt.some(
        ReachabilityConfig(
          version: AutonatV1,
          scheduleInterval: scheduleInterval,
          v2ServiceConfig: Opt.none(AutonatV2ServiceConfig),
        )
      )
    else:
      let v2ServiceConfig =
        if scheduleInterval.isSome():
          Opt.some(AutonatV2ServiceConfig.new(scheduleInterval = scheduleInterval))
        else:
          Opt.none(AutonatV2ServiceConfig)
      nat.reachability = Opt.some(
        ReachabilityConfig(
          version: AutonatV2,
          scheduleInterval: scheduleInterval,
          v2ServiceConfig: v2ServiceConfig,
        )
      )

  if config.natHolePunching:
    let maxNumRelays =
      if config.natHolePunchingMaxNumRelays > 0:
        config.natHolePunchingMaxNumRelays
      else:
        1
    nat.holePunching = Opt.some(
      HolePunchingConfig(
        maxNumRelays: maxNumRelays,
        onReservation: nil,
        scheduleInterval: optDurationMs(config.natHolePunchingScheduleIntervalMs),
      )
    )

  if nat.portMapping.isNone() and nat.reachability.isNone() and nat.holePunching.isNone():
    ok(Opt.none(NATConfig))
  else:
    ok(Opt.some(nat))

proc parse(config: Libp2pConfig): Result[ParsedConfig, string] =
  let transport = parseTransportConfig(config)
  let dnsServers = ?resolveDnsServers(config.dnsResolver)
  let addrs = ?parseMultiaddrs(config.addrs)
  let privKey = ?parsePrivateKey(config.privKey)
  let bootstrapNodes = ?parseBootstrapNodes(config.bootstrapNodes)
  let nat = ?parseNATConfig(config)

  ok(
    ParsedConfig(
      dnsServers: dnsServers,
      addrs: addrs,
      transport: transport,
      privKey: privKey,
      bootstrapNodes: bootstrapNodes,
      maxConnections: config.maxConnections,
      maxIn: config.maxIn,
      maxOut: config.maxOut,
      maxConnsPerPeer: config.maxConnsPerPeer,
      circuitRelay: config.circuitRelay,
      circuitRelayClient: config.circuitRelayClient,
      autonat: config.autonat,
      nat: nat,
      autonatV2Server: config.autonatV2Server,
      mountGossipsub: config.mountGossipsub,
      gossipsubTriggerSelf: config.gossipsubTriggerSelf,
      mountKad: config.mountKad,
      mountServiceDiscovery: config.mountServiceDiscovery,
    )
  )

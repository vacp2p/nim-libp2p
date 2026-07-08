# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Config crossing the FFI boundary and its parsing, `include`d into
## `../libp2p_ffi.nim`.
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

type TransportType {.pure.} = enum
  QUIC
  TCP

type MuxerType {.pure.} = enum
  MPLEX
  YAMUX

type BootstrapNode {.ffi.} = object
  peerId: string
  multiaddrs: seq[string]

type Libp2pConfig {.ffi.} = object
  mountGossipsub: bool
  gossipsubTriggerSelf: bool
  mountKad: bool
  mountServiceDiscovery: bool
  dnsResolver: string
  addrs: seq[string]
  # `MuxerType`/`TransportType` ordinals, passed as `int` because nim-ffi can't
  # yet carry a Nim enum across the wire (see parseMuxer/parseTransport).
  muxer: int
  transport: int
  bootstrapNodes: seq[BootstrapNode]
  privKey: seq[byte]
  maxConnections: int
  maxIn: int
  maxOut: int
  maxConnsPerPeer: int
  circuitRelay: bool
  circuitRelayClient: bool
  autonat: bool
  autonatV2: bool
  autonatV2Server: bool

type ParsedTransport = object
  ## The transport to build, plus the muxer it needs. A muxer is only used with
  ## TCP, so the variant makes "no muxer for QUIC" unrepresentable rather than
  ## carrying a meaningless default.
  case kind: TransportType
  of TransportType.TCP:
    muxer: MuxerType
  of TransportType.QUIC:
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
  autonatV2: bool
  autonatV2Server: bool
  mountGossipsub: bool
  gossipsubTriggerSelf: bool
  mountKad: bool
  mountServiceDiscovery: bool

func parseTransport(v: int): Result[TransportType, string] =
  case v
  of ord(TransportType.QUIC):
    ok(TransportType.QUIC)
  of ord(TransportType.TCP):
    ok(TransportType.TCP)
  else:
    err("invalid transport ordinal: " & $v)

func parseMuxer(v: int): Result[MuxerType, string] =
  case v
  of ord(MuxerType.MPLEX):
    ok(MuxerType.MPLEX)
  of ord(MuxerType.YAMUX):
    ok(MuxerType.YAMUX)
  else:
    err("invalid muxer ordinal: " & $v)

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

func parseTransportConfig(config: Libp2pConfig): Result[ParsedTransport, string] =
  # A muxer is only used with TCP; a QUIC config's `muxer` ordinal is left
  # unvalidated, matching the transport it applies to.
  let transport = ?parseTransport(config.transport)
  case transport
  of TransportType.QUIC:
    ok(ParsedTransport(kind: TransportType.QUIC))
  of TransportType.TCP:
    let muxer = ?parseMuxer(config.muxer)
    ok(ParsedTransport(kind: TransportType.TCP, muxer: muxer))

proc parse(config: Libp2pConfig): Result[ParsedConfig, string] =
  let transport = ?parseTransportConfig(config)
  let dnsServers = ?resolveDnsServers(config.dnsResolver)
  let addrs = ?parseMultiaddrs(config.addrs)
  let privKey = ?parsePrivateKey(config.privKey)
  let bootstrapNodes = ?parseBootstrapNodes(config.bootstrapNodes)

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
      autonatV2: config.autonatV2,
      autonatV2Server: config.autonatV2Server,
      mountGossipsub: config.mountGossipsub,
      gossipsubTriggerSelf: config.gossipsubTriggerSelf,
      mountKad: config.mountKad,
      mountServiceDiscovery: config.mountServiceDiscovery,
    )
  )

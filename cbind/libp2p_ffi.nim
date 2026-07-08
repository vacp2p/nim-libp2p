# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## C FFI bindings for nim-libp2p, built on top of `nim-ffi`.
##
## `nim-ffi` provides the FFI runtime and generates the C/CDDL bindings. This
## file only declares the library state, the request/response shapes and the
## libp2p-specific bodies; `genBindings()` at the bottom emits the foreign
## bindings consumed by `logos-co/logos-libp2p-module`.
##
## The `{.ffi.}` config types and all of their parsing live in
## `libp2p_ffi/config.nim`, `include`d below — see that file for the
## `config.parse()` entry point and for why it is included rather than imported.

import ffi

import std/[tables, sequtils]

import ../libp2p
import ../libp2p/[multiaddress, peerid]
import ../libp2p/crypto/crypto
import ../libp2p/crypto/secp
import ../libp2p/nameresolving/dnsresolver
import ../libp2p/protocols/pubsub/gossipsub
import ../libp2p/protocols/protocol
import ../libp2p/protocols/ping
import ../libp2p/protocols/kademlia
import ../libp2p/protocols/service_discovery
import ../libp2p/protocols/service_discovery/types
import ../libp2p/protocols/connectivity/relay/client

type StreamRegistry = object
  ## Owns the live streams handed out across the FFI boundary.
  streams: Table[uint64, Stream]
  nextStreamId: uint64

type LibP2P* = ref object
  ## Main library state. The FFI context owns one instance; its tables mutate
  ## through the `lib` receiver of every `{.ffi.}` proc.
  switch: Switch
  rng: Rng
  gossipSub: Opt[GossipSub]
  kad: Opt[KadDHT]
  relayClient: Opt[RelayClient]
  topicHandlers: Table[string, TopicHandler]
  customProtocols: Table[string, LPProtocol]
  streams: StreamRegistry
  stopped: bool ## Guards shutdownSwitch so stop-then-destroy doesn't double-stop.

declareLibrary("libp2p", LibP2P)

include "libp2p_ffi/config"

type PeerInfoResponse {.ffi.} = object
  peerId: string
  addrs: seq[string]

type PeersResponse {.ffi.} = object
  peerIds: seq[string]

type ConnectRequest {.ffi.} = object
  peerId: string
  multiaddrs: seq[string]
  timeoutMs: int64

type DialRequest {.ffi.} = object
  peerId: string
  proto: string

type DialResponse {.ffi.} = object
  streamId: uint64

type DialCircuitRelayRequest {.ffi.} = object
  peerId: string
  multiaddr: string
  proto: string

proc register(reg: var StreamRegistry, stream: Stream): uint64 =
  reg.nextStreamId.inc()
  let id = reg.nextStreamId
  reg.streams[id] = stream
  id

func get(reg: StreamRegistry, id: uint64): Result[Stream, string] =
  let stream = reg.streams.getOrDefault(id, nil)
  if stream.isNil():
    return err("unknown stream handle")
  ok(stream)

proc parseMultiaddrs(addrs: seq[string]): Result[seq[MultiAddress], string] =
  var parsed: seq[MultiAddress]
  for a in addrs:
    let ma = MultiAddress.init(a).valueOr:
      return err("invalid multiaddress '" & a & "': " & $error)
    parsed.add(ma)
  ok(parsed)

const MaxReadBytes = 64 * 1024 * 1024
  ## Upper bound on a single stream read. Caps the buffer an untrusted peer can
  ## make us pre-allocate before any byte arrives; well above libp2p's largest
  ## framed messages, so legitimate reads are unaffected.

proc mountGossipsub(lib: LibP2P, triggerSelf: bool): Result[void, string] =
  let gs = GossipSub.init(switch = lib.switch, triggerSelf = triggerSelf, rng = lib.rng)
  try:
    lib.switch.mount(gs)
  except LPError as e:
    return err(e.msg)
  lib.gossipSub = Opt.some(gs)
  ok()

proc defaultKadConfig(): KadDHTConfig =
  # Validator/selector are host callbacks that can't cross the FFI boundary, so
  # fall back to the defaults.
  KadDHTConfig.new(
    validator = DefaultEntryValidator(), selector = DefaultEntrySelector()
  )

proc mountKad(
    lib: LibP2P, bootstrapNodes: seq[(PeerId, seq[MultiAddress])]
): Result[void, string] =
  try:
    let k = KadDHT.new(
      lib.switch,
      bootstrapNodes = bootstrapNodes,
      config = defaultKadConfig(),
      rng = lib.rng,
    )
    lib.switch.mount(k)
    lib.kad = Opt.some(k)
  except LPError as e:
    return err(e.msg)
  ok()

proc mountServiceDiscovery(
    lib: LibP2P, bootstrapNodes: seq[(PeerId, seq[MultiAddress])]
): Result[void, string] =
  try:
    let sd = ServiceDiscovery.new(
      lib.switch,
      bootstrapNodes = bootstrapNodes,
      config = defaultKadConfig(),
      rng = lib.rng,
      codec = ExtendedServiceDiscoveryCodec,
    )
    lib.switch.mount(sd)
    lib.kad = Opt.some(KadDHT(sd))
  except LPError as e:
    return err(e.msg)
  ok()

proc mountProtocols(lib: LibP2P, cfg: ParsedConfig): Result[void, string] =
  if cfg.mountGossipsub:
    ?mountGossipsub(lib, cfg.gossipsubTriggerSelf)

  if cfg.mountServiceDiscovery:
    ?mountServiceDiscovery(lib, cfg.bootstrapNodes)
  elif cfg.mountKad:
    ?mountKad(lib, cfg.bootstrapNodes)

  try:
    lib.switch.mount(Ping.new(rng = lib.rng))
  except LPError as e:
    return err(e.msg)
  ok()

proc withConfiguredTransport(
    builder: SwitchBuilder, transport: ParsedTransport
): SwitchBuilder =
  case transport.kind
  of TransportType.QUIC:
    builder.withQuicTransport()
  of TransportType.TCP:
    let tcp = builder.withTcpTransport()
    case transport.muxer
    of MuxerType.MPLEX:
      tcp.withMplex()
    of MuxerType.YAMUX:
      tcp.withYamux()

proc createLibp2pNode(config: Libp2pConfig): Result[LibP2P, string] =
  let cfg = ?config.parse()
  let rng = newRng()

  var switchBuilder = SwitchBuilder
    .new()
    .withRng(rng)
    .withMaxConnsPerPeer(cfg.maxConnsPerPeer)
    .withNameResolver(DnsResolver.new(cfg.dnsServers))
    .withNoise()
    .withPrivateKey(cfg.privKey)
    .withAddresses(cfg.addrs)
    .withConfiguredTransport(cfg.transport)

  if cfg.maxIn > 0 and cfg.maxOut > 0:
    switchBuilder = switchBuilder.withConnectionLimits(
      ConnectionLimits.maxInOut(cfg.maxIn, cfg.maxOut)
    )
  elif cfg.maxConnections > 0:
    switchBuilder =
      switchBuilder.withConnectionLimits(ConnectionLimits.maxTotal(cfg.maxConnections))

  var relayClientOpt = Opt.none(RelayClient)
  if cfg.circuitRelayClient:
    let cl = RelayClient.new()
    switchBuilder = switchBuilder.withCircuitRelay(cl)
    relayClientOpt = Opt.some(cl)
  elif cfg.circuitRelay:
    switchBuilder = switchBuilder.withCircuitRelay()

  if cfg.autonat:
    switchBuilder = switchBuilder.withAutonat()

  if cfg.autonatV2:
    switchBuilder = switchBuilder.withNAT(autonatConfig(AutonatV2))

  if cfg.autonatV2Server:
    switchBuilder = switchBuilder.withAutonatV2Server()

  let switch =
    try:
      switchBuilder.build()
    except LPError as e:
      return err("could not create libp2p node: " & e.msg)

  let lib = LibP2P(switch: switch, rng: rng, relayClient: relayClientOpt)

  ?mountProtocols(lib, cfg)

  ok(lib)

proc libp2pNew*(config: Libp2pConfig): Future[Result[LibP2P, string]] {.ffiCtor.} =
  try:
    createLibp2pNode(config)
  except LPError as e:
    err("could not create libp2p node: " & e.msg)

proc shutdownSwitch(lib: LibP2P) {.async.} =
  ## Single source of truth for graceful shutdown. Idempotent: safe to call from
  ## both an explicit `libp2pStop` and `libp2pDestroy`'s teardown.
  if lib.stopped:
    return
  lib.stopped = true
  await lib.switch.stop()

proc libp2pStart*(lib: LibP2P): Future[Result[void, string]] {.ffi.} =
  try:
    await lib.switch.start()
  except LPError as e:
    return err(e.msg)
  ok()

proc libp2pStop*(lib: LibP2P): Future[Result[void, string]] {.ffi.} =
  await shutdownSwitch(lib)
  ok()

proc libp2pDestroy*(lib: LibP2P): Future[void] {.ffiDtor.} =
  ## Owns the full teardown: the FFI runtime runs this on the worker loop at
  ## shutdown, so the switch is gracefully stopped before the threads are joined
  ## and the context is freed. Destroy alone is sufficient; libp2pStop is
  ## optional and only useful for an explicit, error-reporting shutdown.
  await shutdownSwitch(lib)

# Hand-maintained C-ABI mirror of `Libp2pConfig`: the `{.ffi.}` config crosses as
# CBOR, not a C struct, so it's absent from the generated bindings. Keep in sync.
type CLibp2pConfig {.exportc: "libp2p_config", bycopy.} = object
  mountGossipsub: cint
  gossipsubTriggerSelf: cint
  mountKad: cint
  mountServiceDiscovery: cint
  dnsResolver: cstring
  addrs: ptr cstring
  addrsLen: csize_t
  muxer: cint
  transport: cint
  bootstrapNodes: pointer
  bootstrapNodesLen: csize_t
  privKey: ptr byte
  privKeyLen: csize_t
  maxConnections: cint
  maxIn: cint
  maxOut: cint
  maxConnsPerPeer: cint
  circuitRelay: cint
  circuitRelayClient: cint
  autonat: cint
  autonatV2: cint
  autonatV2Server: cint

proc libp2pNewDefaultConfig(): CLibp2pConfig {.
    exportc: "libp2p_new_default_config", cdecl, dynlib
.} =
  CLibp2pConfig()

proc libp2pPublicKey*(lib: LibP2P): Future[Result[seq[byte], string]] {.ffi.} =
  let peerInfo = lib.switch.peerInfo
  if peerInfo.isNil():
    return err("switch peerInfo is nil")

  let pubKey =
    case peerInfo.publicKey.scheme
    of PKScheme.Secp256k1:
      peerInfo.publicKey.skkey
    else:
      return err("peerInfo public key must be secp256k1")

  ok(@(pubKey.getBytes()))

proc libp2pConnect*(
    lib: LibP2P, req: ConnectRequest
): Future[Result[void, string]] {.ffi: "timeout = 30000".} =
  # The FFI runtime caps every handler at a 5s default; a dial+upgrade can take
  # up to libp2p's 30s UpgradeTimeout, so raise the backstop to match. The
  # per-call `req.timeoutMs` still governs below whenever it is shorter.
  let multiaddresses = parseMultiaddrs(req.multiaddrs).valueOr:
    return err(error)

  let peerId = PeerId.init(req.peerId).valueOr:
    return err($error)

  let timeout =
    if req.timeoutMs <= 0:
      InfiniteDuration
    else:
      chronos.milliseconds(req.timeoutMs)

  try:
    await lib.switch.connect(peerId, multiaddresses).wait(timeout)
  except AsyncTimeoutError:
    return err("dial timeout")
  except DialFailedError as e:
    return err(e.msg)

  ok()

proc libp2pDisconnect*(
    lib: LibP2P, peerId: string
): Future[Result[void, string]] {.ffi.} =
  let pid = PeerId.init(peerId).valueOr:
    return err($error)
  await lib.switch.disconnect(pid)
  ok()

proc libp2pPeerInfo*(lib: LibP2P): Future[Result[PeerInfoResponse, string]] {.ffi.} =
  let peerInfo = lib.switch.peerInfo
  if peerInfo.isNil():
    return err("switch peerInfo is nil")
  try:
    ok(PeerInfoResponse(peerId: $peerInfo.peerId, addrs: peerInfo.addrs.mapIt($it)))
  except LPError as e:
    err(e.msg)

proc libp2pConnectedPeers*(
    lib: LibP2P, direction: int
): Future[Result[PeersResponse, string]] {.ffi.} =
  let dir =
    case direction
    of ord(Direction.In):
      Direction.In
    of ord(Direction.Out):
      Direction.Out
    else:
      return err("invalid direction: " & $direction)

  let peers = lib.switch.connectedPeers(dir)
  ok(PeersResponse(peerIds: peers.mapIt($it)))

proc libp2pDial*(
    lib: LibP2P, req: DialRequest
): Future[Result[DialResponse, string]] {.ffi: "timeout = 30000".} =
  # See libp2pConnect: a dial can run to the 30s UpgradeTimeout, so the handler
  # needs more than the FFI runtime's 5s default or the caller is unblocked with
  # a spurious timeout while this handler keeps running and leaks the streamId.
  let peerId = PeerId.init(req.peerId).valueOr:
    return err($error)
  let stream =
    try:
      await lib.switch.dial(peerId, req.proto)
    except DialFailedError as e:
      return err(e.msg)
  ok(DialResponse(streamId: lib.streams.register(stream)))

proc libp2pDialCircuitRelay*(
    lib: LibP2P, req: DialCircuitRelayRequest
): Future[Result[DialResponse, string]] {.ffi: "timeout = 30000".} =
  let dstPeerId = PeerId.init(req.peerId).valueOr:
    return err($error)
  let relayCircuitAddr = MultiAddress.init(req.multiaddr).valueOr:
    return err($error)
  let stream =
    try:
      await lib.switch.dial(dstPeerId, @[relayCircuitAddr], req.proto)
    except DialFailedError as e:
      return err(e.msg)
  ok(DialResponse(streamId: lib.streams.register(stream)))

genBindings()

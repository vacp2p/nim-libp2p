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
from std/times import getTime, toUnix

import ../libp2p
import ../libp2p/[multiaddress, peerid]
import ../libp2p/crypto/crypto
import ../libp2p/nameresolving/dnsresolver
import ../libp2p/protocols/pubsub/gossipsub
import ../libp2p/protocols/protocol
import ../libp2p/protocols/ping
import ../libp2p/protocols/kademlia
import ../libp2p/protocols/service_discovery
import ../libp2p/protocols/service_discovery/[random_find, types]
import ../libp2p/protocols/connectivity/relay/client
import ../libp2p/extended_peer_record

type StreamRegistry = ref object
  ## Owns the live streams handed out across the FFI boundary and the
  ## release-waiter futures that keep custom-protocol handlers alive until the
  ## host is done with the stream. A `ref` so the custom-protocol handler can
  ## capture it directly instead of the whole `LibP2P`, which would form a
  ## `lib -> customProtocols -> handler -> lib` cycle that `--mm:refc` leaks.
  streams: Table[uint64, Stream]
  nextStreamId: uint64
  releaseWaiters: Table[uint64, Future[void].Raising([CancelledError])]

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
  running: bool

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
  timeoutMs: int64

type DialResponse {.ffi.} = object
  streamId: uint64

type DialCircuitRelayRequest {.ffi.} = object
  peerId: string
  multiaddr: string
  proto: string
  timeoutMs: int64

type StreamWriteRequest {.ffi.} = object
  streamId: uint64
  data: seq[byte]

type StreamReadExactlyRequest {.ffi.} = object
  streamId: uint64
  numBytes: int64

type StreamReadLpRequest {.ffi.} = object
  streamId: uint64
  maxSize: int64

type PublishRequest {.ffi.} = object
  topic: string
  data: seq[byte]

type PublishResponse {.ffi.} = object
  peerCount: int64 ## number of peers the message was forwarded to

type ReadResponse {.ffi.} = object
  data: seq[byte]

type CreateCidRequest {.ffi.} = object
  version: int
  multicodec: string
  hash: string
  data: seq[byte]

type NewPrivateKeyRequest {.ffi.} = object
  scheme: int

type KadPutValueRequest {.ffi.} = object
  key: seq[byte]
  value: seq[byte]

type KadGetValueRequest {.ffi.} = object
  key: seq[byte]
  quorum: int

type ProviderInfo {.ffi.} = object
  peerId: string
  addrs: seq[string]

type ProvidersResponse {.ffi.} = object
  providers: seq[ProviderInfo]

type ServiceInfoEntry {.ffi.} = object
  id: string
  data: seq[byte]

type ExtendedPeerRecordEntry {.ffi.} = object
  peerId: string
  seqNo: uint64
  addrs: seq[string]
  services: seq[ServiceInfoEntry]

type ExtendedRecordsResponse {.ffi.} = object
  records: seq[ExtendedPeerRecordEntry]

type StartAdvertisingRequest {.ffi.} = object
  serviceId: string
  serviceData: seq[byte]

type CreateXprRequest {.ffi.} = object
  addrs: seq[string]
  services: seq[ServiceInfoEntry]
  seqNo: uint64

type DecodeXprRequest {.ffi.} = object
  encoded: seq[byte]

type LookupRequest {.ffi.} = object
  serviceId: string
  serviceData: seq[byte]

type IncomingStreamEvent {.ffi.} = object
  proto: string
  streamId: uint64

type PubsubMessageEvent {.ffi.} = object
  topic: string
  data: seq[byte]

proc onIncomingStream*(event: IncomingStreamEvent) {.ffiEvent: "on_incoming_stream".}

proc onPubsubMessage*(event: PubsubMessageEvent) {.ffiEvent: "on_pubsub_message".}

proc register(reg: StreamRegistry, stream: Stream): uint64 =
  reg.nextStreamId.inc()
  let id = reg.nextStreamId
  reg.streams[id] = stream
  id

func get(reg: StreamRegistry, id: uint64): Result[Stream, string] =
  let stream = reg.streams.getOrDefault(id, nil)
  if stream.isNil():
    return err("unknown stream handle")
  ok(stream)

proc release(reg: StreamRegistry, id: uint64) =
  # Completes the waiting protocol handler so multistream doesn't close the stream early.
  let releaseWaiter = reg.releaseWaiters.getOrDefault(id, nil)
  if not releaseWaiter.isNil():
    reg.releaseWaiters.del(id)
    if not releaseWaiter.finished():
      releaseWaiter.complete()
  reg.streams.del(id)

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

  let lib = LibP2P(
    switch: switch, rng: rng, relayClient: relayClientOpt, streams: StreamRegistry()
  )

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
  if not lib.running:
    return
  await lib.switch.stop()
  lib.running = false

proc libp2pStart*(lib: LibP2P): Future[Result[bool, string]] {.ffi.} =
  if lib.running:
    return ok(true)
  try:
    await lib.switch.start()
  except LPError as e:
    return err(e.msg)
  lib.running = true
  ok(true)

proc libp2pStop*(lib: LibP2P): Future[Result[bool, string]] {.ffi.} =
  await shutdownSwitch(lib)
  ok(true)

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

  # Scheme-native serialization, so whatever key the switch was built with
  # round-trips — not just secp256k1. The default builder uses Ed25519.
  let rawBytes = peerInfo.publicKey.getRawBytes().valueOr:
    return err("could not serialize public key: " & $error)
  ok(rawBytes)

func dialTimeout(timeoutMs: int64): Duration =
  ## The caller-supplied bound on a single dial. `<= 0` opts out
  ## (`InfiniteDuration`), deferring to libp2p's own dial timeout — which is
  ## still capped by the FFI handler backstop (see libp2pConnect).
  if timeoutMs <= 0:
    InfiniteDuration
  else:
    chronos.milliseconds(timeoutMs)

proc libp2pConnect*(
    lib: LibP2P, req: ConnectRequest
): Future[Result[bool, string]] {.ffi: "timeout = 30000".} =
  # The FFI runtime caps every handler at a 5s default; a dial+upgrade can take
  # up to libp2p's 30s UpgradeTimeout, so raise the backstop to match. The
  # per-call `req.timeoutMs` bounds the dial itself whenever it is shorter.
  let multiaddresses = parseMultiaddrs(req.multiaddrs).valueOr:
    return err(error)

  let peerId = PeerId.init(req.peerId).valueOr:
    return err($error)

  try:
    await lib.switch.connect(peerId, multiaddresses).wait(dialTimeout(req.timeoutMs))
  except AsyncTimeoutError:
    return err("dial timeout")
  except DialFailedError as e:
    return err(e.msg)

  ok(true)

proc libp2pDisconnect*(
    lib: LibP2P, peerId: string
): Future[Result[bool, string]] {.ffi.} =
  let pid = PeerId.init(peerId).valueOr:
    return err($error)
  await lib.switch.disconnect(pid)
  ok(true)

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
  # `req.timeoutMs` bounds the dial itself.
  let peerId = PeerId.init(req.peerId).valueOr:
    return err($error)
  let stream =
    try:
      await lib.switch.dial(peerId, req.proto).wait(dialTimeout(req.timeoutMs))
    except AsyncTimeoutError:
      return err("dial timeout")
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
      await lib.switch.dial(dstPeerId, @[relayCircuitAddr], req.proto).wait(
        dialTimeout(req.timeoutMs)
      )
    except AsyncTimeoutError:
      return err("dial timeout")
    except DialFailedError as e:
      return err(e.msg)
  ok(DialResponse(streamId: lib.streams.register(stream)))

func validateReadLength(n: int64): Result[int, string] =
  ## Guards attacker-controlled read lengths before they size an allocation:
  ## rejects negatives and anything past the `MaxReadBytes` DoS ceiling. The
  ## ceiling (64 MiB) sits well below `int.high` even on 32-bit targets, so the
  ## `int(n)` narrowing below is always safe; `int.high` stays as a backstop in
  ## case the ceiling is ever raised.
  if n < 0:
    return err("invalid read length")
  if n > MaxReadBytes:
    return err("read length exceeds maximum")
  if n > int.high:
    return err("read length too large")
  ok(int(n))

proc libp2pStreamReadExactly*(
    lib: LibP2P, req: StreamReadExactlyRequest
): Future[Result[ReadResponse, string]] {.ffi.} =
  let stream = ?lib.streams.get(req.streamId)
  let expected = ?validateReadLength(req.numBytes)
  if expected == 0:
    return ok(ReadResponse(data: @[]))
  var buf = newSeqUninit[byte](expected)
  try:
    await stream.readExactly(addr buf[0], expected)
  except LPStreamError as e:
    return err(e.msg)
  ok(ReadResponse(data: buf))

proc libp2pStreamReadLp*(
    lib: LibP2P, req: StreamReadLpRequest
): Future[Result[ReadResponse, string]] {.ffi.} =
  let stream = ?lib.streams.get(req.streamId)
  let maxSize = ?validateReadLength(req.maxSize)
  let data =
    try:
      await stream.readLp(maxSize)
    except LPStreamError as e:
      return err(e.msg)
  ok(ReadResponse(data: data))

proc libp2pStreamWrite*(
    lib: LibP2P, req: StreamWriteRequest
): Future[Result[bool, string]] {.ffi.} =
  let stream = ?lib.streams.get(req.streamId)
  try:
    await stream.write(req.data)
  except LPStreamError as e:
    return err(e.msg)
  ok(true)

proc libp2pStreamWriteLp*(
    lib: LibP2P, req: StreamWriteRequest
): Future[Result[bool, string]] {.ffi.} =
  let stream = ?lib.streams.get(req.streamId)
  try:
    await stream.writeLp(req.data)
  except LPStreamError as e:
    return err(e.msg)
  ok(true)

proc libp2pStreamClose*(
    lib: LibP2P, streamId: uint64
): Future[Result[bool, string]] {.ffi.} =
  let stream = ?lib.streams.get(streamId)
  await stream.close()
  ok(true)

proc libp2pStreamCloseWithEof*(
    lib: LibP2P, streamId: uint64
): Future[Result[bool, string]] {.ffi.} =
  let stream = ?lib.streams.get(streamId)
  await stream.closeWithEOF()
  ok(true)

proc libp2pStreamRelease*(
    lib: LibP2P, streamId: uint64
): Future[Result[bool, string]] {.ffi.} =
  discard ?lib.streams.get(streamId)
  lib.streams.release(streamId)
  ok(true)

proc libp2pMountProtocol*(
    lib: LibP2P, proto: string
): Future[Result[bool, string]] {.ffi.} =
  if proto.len == 0:
    return err("proto is empty")
  if lib.switch.isNil():
    return err("libp2p switch is not initialized")

  let peerInfo = lib.switch.peerInfo
  if lib.customProtocols.hasKey(proto) or proto in peerInfo.protocols:
    return err("protocol already mounted: " & proto)

  # Capture the registry ref, not `lib`: a closure over `lib` stored back into
  # `lib.customProtocols` would cycle and leak under `--mm:refc`.
  let streams = lib.streams
  proc handle(
      stream: Stream, selectedProto: string
  ) {.async: (raises: [CancelledError]).} =
    let streamId = streams.register(stream)
    defer:
      streams.release(streamId)
    let releaseWaiter =
      Future[void].Raising([CancelledError]).init("cbind custom protocol release")
    streams.releaseWaiters[streamId] = releaseWaiter
    onIncomingStream(IncomingStreamEvent(proto: selectedProto, streamId: streamId))
    await releaseWaiter

  let mountedProtocol = LPProtocol.new(codecs = @[proto], handler = handle)
  await mountedProtocol.start()

  try:
    lib.switch.mount(mountedProtocol)
  except LPError as e:
    await mountedProtocol.stop()
    return err(e.msg)

  lib.customProtocols[proto] = mountedProtocol
  ok(true)

proc libp2pGossipsubPublish*(
    lib: LibP2P, req: PublishRequest
): Future[Result[PublishResponse, string]] {.ffi.} =
  let gossipSub = lib.gossipSub.valueOr:
    return err("gossipsub not initialized")
  let peerCount = await gossipSub.publish(req.topic, req.data)
  ok(PublishResponse(peerCount: peerCount.int64))

proc libp2pGossipsubSubscribe*(
    lib: LibP2P, topic: string
): Future[Result[bool, string]] {.ffi.} =
  let gossipSub = lib.gossipSub.valueOr:
    return err("gossipsub not initialized")
  if not lib.topicHandlers.hasKey(topic):
    let handler = proc(t: string, data: seq[byte]): Future[void] {.async.} =
      onPubsubMessage(PubsubMessageEvent(topic: t, data: data))
    lib.topicHandlers[topic] = handler
    gossipSub.subscribe(topic, handler)
  ok(true)

proc libp2pGossipsubUnsubscribe*(
    lib: LibP2P, topic: string
): Future[Result[bool, string]] {.ffi.} =
  let gossipSub = lib.gossipSub.valueOr:
    return err("gossipsub not initialized")
  let handler = lib.topicHandlers.getOrDefault(topic, nil)
  if not handler.isNil():
    lib.topicHandlers.del(topic)
    gossipSub.unsubscribe(topic, handler)
  ok(true)

func toExtendedRecordEntry(record: ExtendedPeerRecord): ExtendedPeerRecordEntry =
  ExtendedPeerRecordEntry(
    peerId: $record.peerId,
    seqNo: record.seqNo,
    addrs: record.addresses.mapIt($it.address),
    services: record.services.mapIt(ServiceInfoEntry(id: it.id, data: it.data.get(@[]))),
  )

func toExtendedRecordsResponse(
    records: seq[ExtendedPeerRecord]
): ExtendedRecordsResponse =
  ExtendedRecordsResponse(records: records.mapIt(toExtendedRecordEntry(it)))

proc libp2pKadFindNode*(
    lib: LibP2P, peerId: string
): Future[Result[PeersResponse, string]] {.ffi.} =
  let kad = lib.kad.valueOr:
    return err("kad-dht not initialized")
  let target = PeerId.init(peerId).valueOr:
    return err($error)
  let peers =
    try:
      await kad.findNode(target.toKey())
    except LPError as e:
      return err(e.msg)
  ok(PeersResponse(peerIds: peers.mapIt($it)))

proc libp2pKadPutValue*(
    lib: LibP2P, req: KadPutValueRequest
): Future[Result[bool, string]] {.ffi.} =
  let kad = lib.kad.valueOr:
    return err("kad-dht not initialized")
  let res = await kad.putValue(req.key, req.value)
  if res.isErr():
    return err(res.error)
  ok(true)

proc libp2pKadGetValue*(
    lib: LibP2P, req: KadGetValueRequest
): Future[Result[ReadResponse, string]] {.ffi.} =
  let kad = lib.kad.valueOr:
    return err("kad-dht not initialized")
  if req.quorum == 0:
    return err("quorum must be greater than 0 (use a negative value for the default)")
  let quorum =
    if req.quorum < 0:
      Opt.none(int)
    else:
      Opt.some(req.quorum)
  let res =
    try:
      await kad.getValue(req.key, quorum)
    except LPError as e:
      return err(e.msg)
  let entry = res.valueOr:
    return err(res.error)
  ok(ReadResponse(data: entry.value))

proc kadAndCid(lib: LibP2P, cid: string): Result[(KadDHT, Cid), string] =
  let kad = lib.kad.valueOr:
    return err("kad-dht not initialized")
  let c = Cid.init(cid).valueOr:
    return err("invalid cid: " & $error)
  ok((kad, c))

proc libp2pKadAddProvider*(
    lib: LibP2P, cid: string
): Future[Result[bool, string]] {.ffi.} =
  let (kad, c) = kadAndCid(lib, cid).valueOr:
    return err(error)
  await kad.addProvider(c)
  ok(true)

proc libp2pKadStartProviding*(
    lib: LibP2P, cid: string
): Future[Result[bool, string]] {.ffi.} =
  let (kad, c) = kadAndCid(lib, cid).valueOr:
    return err(error)
  await kad.startProviding(c)
  ok(true)

proc libp2pKadStopProviding*(
    lib: LibP2P, cid: string
): Future[Result[bool, string]] {.ffi.} =
  let (kad, c) = kadAndCid(lib, cid).valueOr:
    return err(error)
  kad.stopProviding(c)
  ok(true)

proc libp2pKadGetProviders*(
    lib: LibP2P, cid: string
): Future[Result[ProvidersResponse, string]] {.ffi.} =
  let (kad, c) = kadAndCid(lib, cid).valueOr:
    return err(error)
  let providersSet =
    try:
      await kad.getProviders(c.toKey())
    except LPError as e:
      return err(e.msg)

  var providers: seq[ProviderInfo]
  for provider in providersSet.toSeq():
    let providerId = provider.id.valueOr:
      continue
    let peerId = PeerId.init(providerId).valueOr:
      continue
    providers.add(ProviderInfo(peerId: $peerId, addrs: provider.addrs.mapIt($it)))
  ok(ProvidersResponse(providers: providers))

proc resolveServiceDiscovery(lib: LibP2P): Result[ServiceDiscovery, string] =
  let kad = lib.kad.valueOr:
    return err("service discovery not initialized")
  if not (kad of ServiceDiscovery):
    return err("service discovery not mounted")
  ok(ServiceDiscovery(kad))

proc libp2pKadRandomRecords*(
    lib: LibP2P
): Future[Result[ExtendedRecordsResponse, string]] {.ffi.} =
  let disco = resolveServiceDiscovery(lib).valueOr:
    return err(error)
  let records = await disco.lookupRandom()
  ok(toExtendedRecordsResponse(records))

proc libp2pServiceDiscoStart*(lib: LibP2P): Future[Result[bool, string]] {.ffi.} =
  let disco = resolveServiceDiscovery(lib).valueOr:
    return err(error)
  await disco.start()
  ok(true)

proc libp2pServiceDiscoStop*(lib: LibP2P): Future[Result[bool, string]] {.ffi.} =
  let disco = resolveServiceDiscovery(lib).valueOr:
    return err(error)
  await disco.stop()
  ok(true)

proc libp2pServiceDiscoStartAdvertising*(
    lib: LibP2P, req: StartAdvertisingRequest
): Future[Result[bool, string]] {.ffi.} =
  let disco = resolveServiceDiscovery(lib).valueOr:
    return err(error)
  disco.startAdvertising(
    ServiceInfo(id: req.serviceId, data: Opt.some(req.serviceData))
  )
  ok(true)

proc libp2pServiceDiscoStopAdvertising*(
    lib: LibP2P, serviceId: string
): Future[Result[bool, string]] {.ffi.} =
  let disco = resolveServiceDiscovery(lib).valueOr:
    return err(error)
  await disco.stopAdvertising(serviceId)
  ok(true)

proc libp2pServiceDiscoRegisterInterest*(
    lib: LibP2P, serviceId: string
): Future[Result[bool, string]] {.ffi.} =
  let disco = resolveServiceDiscovery(lib).valueOr:
    return err(error)
  discard disco.registerInterest(serviceId)
  ok(true)

proc libp2pServiceDiscoUnregisterInterest*(
    lib: LibP2P, serviceId: string
): Future[Result[bool, string]] {.ffi.} =
  let disco = resolveServiceDiscovery(lib).valueOr:
    return err(error)
  disco.unregisterInterest(serviceId)
  ok(true)

proc libp2pServiceDiscoLookup*(
    lib: LibP2P, req: LookupRequest
): Future[Result[ExtendedRecordsResponse, string]] {.ffi.} =
  let disco = resolveServiceDiscovery(lib).valueOr:
    return err(error)
  let service = ServiceInfo(id: req.serviceId, data: Opt.some(req.serviceData))
  let res = await disco.lookup(service)
  let ads = res.valueOr:
    return err($error)
  ok(toExtendedRecordsResponse(ads.mapIt(it.data)))

proc libp2pServiceDiscoRandomLookup*(
    lib: LibP2P
): Future[Result[ExtendedRecordsResponse, string]] {.ffi.} =
  let disco = resolveServiceDiscovery(lib).valueOr:
    return err(error)
  let records = await disco.lookupRandom()
  ok(toExtendedRecordsResponse(records))

proc libp2pCreateXpr*(
    lib: LibP2P, req: CreateXprRequest
): Future[Result[seq[byte], string]] {.ffi.} =
  let peerInfo = lib.switch.peerInfo
  if peerInfo.isNil():
    return err("switch peerInfo is nil")

  var addresses = parseMultiaddrs(req.addrs).valueOr:
    return err(error)
  if addresses.len == 0:
    addresses = peerInfo.addrs

  let seqNo =
    if req.seqNo == 0:
      getTime().toUnix().uint64
    else:
      req.seqNo

  var services: seq[ServiceInfo]
  for s in req.services:
    services.add(ServiceInfo(id: s.id, data: Opt.some(s.data)))

  let peerRecord = ExtendedPeerRecord.init(
    peerId = peerInfo.peerId, addresses = addresses, seqNo = seqNo, services = services
  )

  let xpr = SignedExtendedPeerRecord.build(peerInfo.privateKey, peerRecord).valueOr:
    return err(error)

  ok(xpr.encode())

proc libp2pDecodeXpr*(
    lib: LibP2P, req: DecodeXprRequest
): Future[Result[ExtendedPeerRecordEntry, string]] {.ffi.} =
  let sxpr = SignedExtendedPeerRecord.decode(req.encoded).valueOr:
    return err("failed to decode signed extended peer record: " & $error)

  sxpr.checkValid().isOkOr:
    return err("invalid XPR signature: " & $error)

  ok(toExtendedRecordEntry(sxpr.data))

proc libp2pCreateCid*(
    lib: LibP2P, req: CreateCidRequest
): Future[Result[string, string]] {.ffi.} =
  let cidVer =
    case req.version
    of 0:
      CIDv0
    of 1:
      CIDv1
    else:
      return err("cid version must be 0 or 1")

  let mc = MultiCodec.codec(req.multicodec)
  if mc == InvalidMultiCodec:
    return err("invalid multicodec: " & req.multicodec)

  let mh = MultiHash.digest(req.hash, req.data).valueOr:
    return err("multihash error: " & $error)

  let cid = Cid.init(cidVer, mc, mh).valueOr:
    return err("cid init error: " & $error)

  ok($cid)

proc libp2pNewPrivateKey*(
    lib: LibP2P, req: NewPrivateKeyRequest
): Future[Result[seq[byte], string]] {.ffi.} =
  if req.scheme < ord(low(PKScheme)) or req.scheme > ord(high(PKScheme)):
    return err("invalid key scheme")
  let scheme = PKScheme(req.scheme)

  let key = PrivateKey.random(scheme, lib.rng).valueOr:
    return err("could not generate private key")

  let keyData = key.getBytes().valueOr:
    return err("could not get bytes for private key")

  ok(keyData)

genBindings()

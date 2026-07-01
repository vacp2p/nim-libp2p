# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## C FFI bindings for nim-libp2p, built on top of `nim-ffi`.
##
## The whole FFI runtime (worker thread, request channel, CBOR codec, event
## queue and the generated C/CDDL bindings) is provided by `nim-ffi`. This
## file only declares the library state, the request/response shapes and the
## libp2p-specific bodies; `genBindings()` at the bottom emits the foreign
## bindings consumed by `logos-co/logos-libp2p-module`.

import ffi

import std/[tables, sequtils, sets, json, jsonutils, strutils, times, locks]
import metrics

import ../libp2p
import ../libp2p/[multiaddress, peerid]
import ../libp2p/crypto/crypto
import ../libp2p/crypto/secp
import ../libp2p/nameresolving/[dnsresolver, nameresolver]
import ../libp2p/protocols/pubsub/gossipsub
import ../libp2p/protocols/protocol
import ../libp2p/protocols/ping
import ../libp2p/protocols/kademlia
import ../libp2p/protocols/service_discovery
import ../libp2p/protocols/service_discovery/[random_find, types]
import ../libp2p/protocols/connectivity/relay/client
import ../libp2p/extended_peer_record

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
  streams: Table[uint64, Stream]
  nextStreamId: uint64
  streamReleaseWaiters: Table[uint64, Future[void].Raising([CancelledError])]

declareLibrary("libp2p", LibP2P)

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

type ReadResponse {.ffi.} = object
  data: seq[byte]

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

type LookupRequest {.ffi.} = object
  serviceId: string
  serviceData: seq[byte]

type ReservationResponse {.ffi.} = object
  addrs: seq[string]
  expireTime: uint64

type CircuitRelayReserveRequest {.ffi.} = object
  relayPeerId: string
  relayAddrs: seq[string]

type AddPeerRequest {.ffi.} = object
  peerId: string
  addrs: seq[string]
  protocols: seq[string]

type SetAddressesRequest {.ffi.} = object
  peerId: string
  addrs: seq[string]

type SetProtocolsRequest {.ffi.} = object
  peerId: string
  protocols: seq[string]

type PeerStoreEntryResponse {.ffi.} = object
  peerId: string
  addrs: seq[string]
  protocols: seq[string]
  publicKey: seq[byte]
  agentVersion: string
  protoVersion: string

type IncomingStreamEvent {.ffi.} = object
  proto: string
  streamId: uint64

type PubsubMessageEvent {.ffi.} = object
  topic: string
  data: seq[byte]

proc onIncomingStream*(event: IncomingStreamEvent) {.ffiEvent: "on_incoming_stream".}

proc onPubsubMessage*(event: PubsubMessageEvent) {.ffiEvent: "on_pubsub_message".}

proc parseTransport(v: int): Result[TransportType, string] =
  case v
  of ord(TransportType.QUIC):
    ok(TransportType.QUIC)
  of ord(TransportType.TCP):
    ok(TransportType.TCP)
  else:
    err("invalid transport")

proc parseMuxer(v: int): Result[MuxerType, string] =
  case v
  of ord(MuxerType.MPLEX):
    ok(MuxerType.MPLEX)
  of ord(MuxerType.YAMUX):
    ok(MuxerType.YAMUX)
  else:
    err("invalid muxer")

proc parseBootstrapNodes(
    config: Libp2pConfig
): Result[seq[(PeerId, seq[MultiAddress])], string] =
  var response: seq[(PeerId, seq[MultiAddress])]
  for node in config.bootstrapNodes:
    let peerId = PeerId.init(node.peerId).valueOr:
      return err("invalid bootstrap peer id: " & $error)
    var addrs: seq[MultiAddress]
    for a in node.multiaddrs:
      let ma = MultiAddress.init(a).valueOr:
        return err("invalid bootstrap multiaddr: " & $error)
      addrs.add(ma)
    response.add((peerId, addrs))
  ok(response)

proc mountGossipsub(lib: LibP2P, config: Libp2pConfig): Result[void, string] =
  if not config.mountGossipsub:
    return ok()
  let gs = GossipSub.init(
    switch = lib.switch, triggerSelf = config.gossipsubTriggerSelf, rng = lib.rng
  )
  try:
    lib.switch.mount(gs)
  except LPError as e:
    return err(e.msg)
  lib.gossipSub = Opt.some(gs)
  ok()

proc mountKad(lib: LibP2P, config: Libp2pConfig): Result[void, string] =
  if not (config.mountKad or config.mountServiceDiscovery):
    return ok()
  let bootstrapNodes = parseBootstrapNodes(config).valueOr:
    return err(error)
  # Validator/selector are host callbacks that can't cross the FFI boundary, so use defaults.
  let kadCfg = KadDHTConfig.new(
    validator = DefaultEntryValidator(), selector = DefaultEntrySelector()
  )
  try:
    if config.mountServiceDiscovery:
      let k = ServiceDiscovery.new(
        lib.switch,
        bootstrapNodes = bootstrapNodes,
        config = kadCfg,
        rng = lib.rng,
        codec = ExtendedServiceDiscoveryCodec,
      )
      lib.switch.mount(k)
      lib.kad = Opt.some(KadDHT(k))
    else:
      let k = KadDHT.new(
        lib.switch, bootstrapNodes = bootstrapNodes, config = kadCfg, rng = lib.rng
      )
      lib.switch.mount(k)
      lib.kad = Opt.some(k)
  except LPError as e:
    return err(e.msg)
  ok()

proc mountProtocols(lib: LibP2P, config: Libp2pConfig): Result[void, string] =
  ?mountGossipsub(lib, config)
  ?mountKad(lib, config)
  try:
    lib.switch.mount(Ping.new(rng = lib.rng))
  except LPError as e:
    return err(e.msg)
  ok()

proc createLibp2pNode(config: Libp2pConfig): Result[LibP2P, string] =
  let dnsServersAddrs =
    if config.dnsResolver.len == 0:
      DefaultDnsServers
    else:
      @[initTAddress(config.dnsResolver)]

  let rng = newRng()

  var privKey = Opt.none(PrivateKey)
  if config.privKey.len > 0:
    PrivateKey.init(config.privKey).withValue(copyKey):
      privKey = Opt.some(copyKey)

  var addrs: seq[MultiAddress]
  for a in config.addrs:
    let address = MultiAddress.init(a).valueOr:
      return err("invalid listen address: " & $error)
    addrs.add(address)

  let transport = parseTransport(config.transport).valueOr:
    return err(error)

  var switchBuilder = SwitchBuilder
    .new()
    .withRng(rng)
    .withMaxConnsPerPeer(config.maxConnsPerPeer)
    .withNameResolver(cast[NameResolver](DnsResolver.new(dnsServersAddrs)))
    .withNoise()
    .withPrivateKey(privKey)
    .withAddresses(addrs)

  case transport
  of TransportType.QUIC:
    switchBuilder = switchBuilder.withQuicTransport()
  of TransportType.TCP:
    switchBuilder = switchBuilder.withTcpTransport()
    let muxer = parseMuxer(config.muxer).valueOr:
      return err(error)
    case muxer
    of MuxerType.MPLEX:
      switchBuilder = switchBuilder.withMplex()
    of MuxerType.YAMUX:
      switchBuilder = switchBuilder.withYamux()

  if config.maxIn > 0 and config.maxOut > 0:
    switchBuilder = switchBuilder.withConnectionLimits(
      ConnectionLimits.maxInOut(config.maxIn, config.maxOut)
    )
  elif config.maxConnections > 0:
    switchBuilder = switchBuilder.withConnectionLimits(
      ConnectionLimits.maxTotal(config.maxConnections)
    )

  var relayClientOpt = Opt.none(RelayClient)
  if config.circuitRelayClient:
    let cl = RelayClient.new()
    switchBuilder = switchBuilder.withCircuitRelay(cl)
    relayClientOpt = Opt.some(cl)
  elif config.circuitRelay:
    switchBuilder = switchBuilder.withCircuitRelay()

  if config.autonat:
    switchBuilder = switchBuilder.withAutonat()

  if config.autonatV2:
    switchBuilder = switchBuilder.withNAT(autonatConfig(AutonatV2))

  if config.autonatV2Server:
    switchBuilder = switchBuilder.withAutonatV2Server()

  let switch =
    try:
      switchBuilder.build()
    except CatchableError as e:
      return err("could not create libp2p node: " & e.msg)

  let lib = LibP2P(switch: switch, rng: rng, relayClient: relayClientOpt)

  ?mountProtocols(lib, config)

  ok(lib)

proc registerStream(lib: LibP2P, stream: Stream): uint64 =
  lib.nextStreamId.inc()
  let id = lib.nextStreamId
  lib.streams[id] = stream
  id

proc libp2pNew*(config: Libp2pConfig): Future[Result[LibP2P, string]] {.ffiCtor.} =
  try:
    return createLibp2pNode(config)
  except CatchableError as e:
    return err("could not create libp2p node: " & e.msg)

proc libp2pDestroy*(lib: LibP2P) {.ffiDtor.} =
  discard

proc libp2pStart*(lib: LibP2P): Future[Result[bool, string]] {.ffi.} =
  try:
    await lib.switch.start()
  except LPError as e:
    return err(e.msg)
  ok(true)

proc libp2pStop*(lib: LibP2P): Future[Result[bool, string]] {.ffi.} =
  await lib.switch.stop()
  ok(true)

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
): Future[Result[bool, string]] {.ffi.} =
  var multiaddresses: seq[MultiAddress]
  for a in req.multiaddrs:
    let ma = MultiAddress.init(a).valueOr:
      return err("invalid multiaddress: " & a)
    multiaddresses.add(ma)

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

  ok(true)

proc libp2pDisconnect*(
    lib: LibP2P, peerId: string
): Future[Result[bool, string]] {.ffi.} =
  let pid = PeerId.init(peerId).valueOr:
    return err($error)
  await lib.switch.disconnect(pid)
  ok(true)

proc libp2pPeerinfo*(lib: LibP2P): Future[Result[PeerInfoResponse, string]] {.ffi.} =
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
): Future[Result[DialResponse, string]] {.ffi.} =
  let peerId = PeerId.init(req.peerId).valueOr:
    return err($error)
  let stream =
    try:
      await lib.switch.dial(peerId, req.proto)
    except DialFailedError as e:
      return err(e.msg)
  ok(DialResponse(streamId: lib.registerStream(stream)))

proc libp2pDialCircuitRelay*(
    lib: LibP2P, req: DialCircuitRelayRequest
): Future[Result[DialResponse, string]] {.ffi.} =
  let dstPeerId = PeerId.init(req.peerId).valueOr:
    return err($error)
  let relayCircuitAddr = MultiAddress.init(req.multiaddr).valueOr:
    return err($error)
  let stream =
    try:
      await lib.switch.dial(dstPeerId, @[relayCircuitAddr], req.proto)
    except DialFailedError as e:
      return err(e.msg)
  ok(DialResponse(streamId: lib.registerStream(stream)))

proc libp2pStreamReadExactly*(
    lib: LibP2P, req: StreamReadExactlyRequest
): Future[Result[ReadResponse, string]] {.ffi.} =
  let stream = lib.streams.getOrDefault(req.streamId, nil)
  if stream.isNil():
    return err("unknown stream handle")
  if req.numBytes < 0:
    return err("invalid read length")
  let expected = int(req.numBytes)
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
  let stream = lib.streams.getOrDefault(req.streamId, nil)
  if stream.isNil():
    return err("unknown stream handle")
  let data =
    try:
      await stream.readLp(int(req.maxSize))
    except LPStreamError as e:
      return err(e.msg)
  ok(ReadResponse(data: data))

proc libp2pStreamWrite*(
    lib: LibP2P, req: StreamWriteRequest
): Future[Result[bool, string]] {.ffi.} =
  let stream = lib.streams.getOrDefault(req.streamId, nil)
  if stream.isNil():
    return err("unknown stream handle")
  try:
    await stream.write(req.data)
  except LPStreamError as e:
    return err(e.msg)
  ok(true)

proc libp2pStreamWriteLp*(
    lib: LibP2P, req: StreamWriteRequest
): Future[Result[bool, string]] {.ffi.} =
  let stream = lib.streams.getOrDefault(req.streamId, nil)
  if stream.isNil():
    return err("unknown stream handle")
  try:
    await stream.writeLp(req.data)
  except LPStreamError as e:
    return err(e.msg)
  ok(true)

proc libp2pStreamClose*(
    lib: LibP2P, streamId: uint64
): Future[Result[bool, string]] {.ffi.} =
  let stream = lib.streams.getOrDefault(streamId, nil)
  if stream.isNil():
    return err("unknown stream handle")
  await stream.close()
  ok(true)

proc libp2pStreamCloseWithEof*(
    lib: LibP2P, streamId: uint64
): Future[Result[bool, string]] {.ffi.} =
  let stream = lib.streams.getOrDefault(streamId, nil)
  if stream.isNil():
    return err("unknown stream handle")
  await stream.closeWithEOF()
  ok(true)

proc libp2pStreamRelease*(
    lib: LibP2P, streamId: uint64
): Future[Result[bool, string]] {.ffi.} =
  if not lib.streams.hasKey(streamId):
    return err("unknown stream handle")

  # Completes the waiting protocol handler so multistream doesn't close the stream early.
  let releaseWaiter = lib.streamReleaseWaiters.getOrDefault(streamId, nil)
  if not releaseWaiter.isNil():
    lib.streamReleaseWaiters.del(streamId)
    if not releaseWaiter.finished:
      releaseWaiter.complete()

  lib.streams.del(streamId)
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

  proc handle(
      stream: Stream, selectedProto: string
  ) {.async: (raises: [CancelledError]).} =
    let streamId = lib.registerStream(stream)
    let releaseWaiter =
      Future[void].Raising([CancelledError]).init("cbind custom protocol release")
    lib.streamReleaseWaiters[streamId] = releaseWaiter
    try:
      onIncomingStream(IncomingStreamEvent(proto: selectedProto, streamId: streamId))
      await releaseWaiter
    finally:
      lib.streamReleaseWaiters.del(streamId)
      lib.streams.del(streamId)

  let mountedProtocol = LPProtocol.new(codecs = @[proto], handler = handle)
  await mountedProtocol.start()

  try:
    lib.switch.mount(mountedProtocol)
  except LPError as e:
    return err(e.msg)

  lib.customProtocols[proto] = mountedProtocol
  ok(true)

proc libp2pGossipsubPublish*(
    lib: LibP2P, req: PublishRequest
): Future[Result[bool, string]] {.ffi.} =
  let gossipSub = lib.gossipSub.valueOr:
    return err("gossipsub not initialized")
  discard await gossipSub.publish(req.topic, req.data)
  ok(true)

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

proc toExtendedRecordEntry(record: ExtendedPeerRecord): ExtendedPeerRecordEntry =
  ExtendedPeerRecordEntry(
    peerId: $record.peerId,
    seqNo: record.seqNo,
    addrs: record.addresses.mapIt($it.address),
    services: record.services.mapIt(
      ServiceInfoEntry(
        id: it.id,
        data:
          if it.data.isSome:
            it.data.get()
          else:
            @[],
      )
    ),
  )

proc toExtendedRecordsResponse(
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
    return err($res.error)
  ok(ReadResponse(data: entry.value))

proc libp2pKadAddProvider*(
    lib: LibP2P, cid: string
): Future[Result[bool, string]] {.ffi.} =
  let kad = lib.kad.valueOr:
    return err("kad-dht not initialized")
  let c = Cid.init(cid).valueOr:
    return err($error)
  await kad.addProvider(c)
  ok(true)

proc libp2pKadStartProviding*(
    lib: LibP2P, cid: string
): Future[Result[bool, string]] {.ffi.} =
  let kad = lib.kad.valueOr:
    return err("kad-dht not initialized")
  let c = Cid.init(cid).valueOr:
    return err($error)
  await kad.startProviding(c)
  ok(true)

proc libp2pKadStopProviding*(
    lib: LibP2P, cid: string
): Future[Result[bool, string]] {.ffi.} =
  let kad = lib.kad.valueOr:
    return err("kad-dht not initialized")
  let c = Cid.init(cid).valueOr:
    return err($error)
  kad.stopProviding(c)
  ok(true)

proc libp2pKadGetProviders*(
    lib: LibP2P, cid: string
): Future[Result[ProvidersResponse, string]] {.ffi.} =
  let kad = lib.kad.valueOr:
    return err("kad-dht not initialized")
  let c = Cid.init(cid).valueOr:
    return err($error)
  let providersSet =
    try:
      await kad.getProviders(c.toKey())
    except LPError as e:
      return err(e.msg)

  var providers: seq[ProviderInfo]
  for provider in providersSet.toSeq():
    let providerId = provider.id.valueOr:
      return err("Provider Id not set")
    let peerId = PeerId.init(providerId).valueOr:
      return err($error)
    providers.add(ProviderInfo(peerId: $peerId, addrs: provider.addrs.mapIt($it)))
  ok(ProvidersResponse(providers: providers))

proc libp2pKadRandomRecords*(
    lib: LibP2P
): Future[Result[ExtendedRecordsResponse, string]] {.ffi.} =
  let kad = lib.kad.valueOr:
    return err("kad-dht not initialized")
  if not (kad of ServiceDiscovery):
    return err("ServiceDiscovery is not mounted")
  let disco = ServiceDiscovery(kad)
  let records = await disco.lookupRandom()
  ok(toExtendedRecordsResponse(records))

proc resolveServiceDiscovery(lib: LibP2P): Result[ServiceDiscovery, string] =
  let kad = lib.kad.valueOr:
    return err("service discovery not initialized")
  if not (kad of ServiceDiscovery):
    return err("service discovery not mounted")
  ok(ServiceDiscovery(kad))

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
  let kad = lib.kad.valueOr:
    return err("kad-dht not initialized")
  if not (kad of ServiceDiscovery):
    return err("ServiceDiscovery is not mounted")
  let disco = ServiceDiscovery(kad)
  let records = await disco.lookupRandom()
  ok(toExtendedRecordsResponse(records))

proc libp2pCreateXpr*(
    lib: LibP2P, req: CreateXprRequest
): Future[Result[seq[byte], string]] {.ffi.} =
  let peerInfo = lib.switch.peerInfo
  if peerInfo.isNil():
    return err("switch peerInfo is nil")

  var addresses: seq[MultiAddress]
  for a in req.addrs:
    let ma = MultiAddress.init(a).valueOr:
      return err("invalid multiaddress '" & a & "': " & $error)
    addresses.add(ma)
  if addresses.len == 0:
    addresses = peerInfo.addrs

  let seqNo =
    if req.seqNo == 0:
      Moment.now().epochSeconds.uint64
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

proc libp2pCircuitRelayReserve*(
    lib: LibP2P, req: CircuitRelayReserveRequest
): Future[Result[ReservationResponse, string]] {.ffi.} =
  let cl = lib.relayClient.valueOr:
    return err("relay client is not mounted (set circuitRelayClient=true in config)")

  let peerId = PeerId.init(req.relayPeerId).valueOr:
    return err($error)

  var multiaddresses: seq[MultiAddress]
  for a in req.relayAddrs:
    let ma = MultiAddress.init(a).valueOr:
      return err("invalid multiaddress: " & a)
    multiaddresses.add(ma)

  let rsvp =
    try:
      await cl.reserve(peerId, multiaddresses)
    except ReservationError as e:
      return err("reservation failed: " & e.msg)
    except DialFailedError as e:
      return err("dial failed: " & e.msg)

  ok(ReservationResponse(addrs: rsvp.addrs.mapIt($it), expireTime: rsvp.expire))

proc libp2pPeerstoreGetPeers*(
    lib: LibP2P
): Future[Result[PeersResponse, string]] {.ffi.} =
  var peerIds: seq[string]
  try:
    for peerId in keys(lib.switch.peerStore[AddressBook].book):
      peerIds.add($peerId)
  except LPError as e:
    return err(e.msg)
  ok(PeersResponse(peerIds: peerIds))

proc libp2pPeerstoreGetPeerInfo*(
    lib: LibP2P, peerId: string
): Future[Result[PeerStoreEntryResponse, string]] {.ffi.} =
  let pid = PeerId.init(peerId).valueOr:
    return err($error)
  let peerStore = lib.switch.peerStore
  try:
    var entry = PeerStoreEntryResponse(peerId: $pid)
    entry.addrs = peerStore[AddressBook][pid].mapIt($it)
    entry.protocols = peerStore[ProtoBook][pid]
    if peerStore[KeyBook].contains(pid):
      entry.publicKey = peerStore[KeyBook][pid].getBytes().valueOr:
        seq[byte].default
    entry.agentVersion = peerStore[AgentBook][pid]
    entry.protoVersion = peerStore[ProtoVersionBook][pid]
    ok(entry)
  except LPError as e:
    err(e.msg)

proc libp2pPeerstoreAddPeer*(
    lib: LibP2P, req: AddPeerRequest
): Future[Result[bool, string]] {.ffi.} =
  let pid = PeerId.init(req.peerId).valueOr:
    return err($error)
  if req.addrs.len == 0:
    return err("at least one address is required")

  var addrs: seq[MultiAddress]
  for a in req.addrs:
    let parsedAddr = MultiAddress.init(a).valueOr:
      return err($error)
    addrs.add(parsedAddr)

  let peerStore = lib.switch.peerStore
  peerStore[AddressBook].extend(pid, addrs)
  if req.protocols.len > 0:
    peerStore[ProtoBook].extend(pid, req.protocols)
  ok(true)

proc libp2pPeerstoreSetPeerAddresses*(
    lib: LibP2P, req: SetAddressesRequest
): Future[Result[bool, string]] {.ffi.} =
  let pid = PeerId.init(req.peerId).valueOr:
    return err($error)

  var addrs: seq[MultiAddress]
  for a in req.addrs:
    let parsedAddr = MultiAddress.init(a).valueOr:
      return err($error)
    addrs.add(parsedAddr)

  lib.switch.peerStore[AddressBook][pid] = addrs
  ok(true)

proc libp2pPeerstoreSetPeerProtocols*(
    lib: LibP2P, req: SetProtocolsRequest
): Future[Result[bool, string]] {.ffi.} =
  let pid = PeerId.init(req.peerId).valueOr:
    return err($error)
  lib.switch.peerStore[ProtoBook][pid] = req.protocols
  ok(true)

proc libp2pPeerstoreDeletePeer*(
    lib: LibP2P, peerId: string
): Future[Result[bool, string]] {.ffi.} =
  let pid = PeerId.init(peerId).valueOr:
    return err($error)
  lib.switch.peerStore.del(pid)
  ok(true)

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

type LabelPair = object
  name: string
  value: string

type MetricEntry = object
  name: string
  `type`: string
  help: string
  labels: seq[LabelPair]
  value: float64
  timestamp: int64

const UntypedMetricKind = "untyped"

proc parseMetricType(typeLine: string): string =
  ## `typeLine` is the collector's pre-formatted "# TYPE <name> <kind>\n";
  ## returns <kind>, or "untyped" when the line is empty or malformed.
  let tokens = typeLine.splitWhitespace()
  if tokens.len < 4:
    return UntypedMetricKind
  tokens[^1]

proc parseMetricHelp(helpLine: string): string =
  ## `helpLine` is the collector's pre-formatted "# HELP <name> <text>\n";
  ## returns <text> (which itself may contain whitespace), or "" when absent.
  const PrefixTokens = 3 # "#", "HELP", "<name>"
  let tokens = helpLine.splitWhitespace(maxsplit = PrefixTokens)
  if tokens.len <= PrefixTokens:
    return ""
  tokens[PrefixTokens].strip()

proc addMetricEntry(
    entries: ptr seq[MetricEntry],
    metricType: string,
    help: string,
    name: string,
    value: float64,
    labels, labelValues: openArray[string],
    timestamp: Time,
) {.gcsafe, raises: [].} =
  # Skip _created entries: OpenMetrics timestamp metadata, not measurements.
  if name.endsWith("_created"):
    return
  doAssert labels.len == labelValues.len, "metric label count mismatch"
  var labelPairs = newSeq[LabelPair](labels.len)
  for i in 0 ..< labels.len:
    labelPairs[i] = LabelPair(name: labels[i], value: labelValues[i])
  entries[].add MetricEntry(
    name: name,
    `type`: metricType,
    help: help,
    labels: labelPairs,
    value: value,
    timestamp: timestamp.toMilliseconds(),
  )

proc collectRegistryMetrics(registry: Registry): seq[MetricEntry] {.gcsafe.} =
  var entries: seq[MetricEntry]
  {.cast(gcsafe).}:
    withLock registry.lock:
      for collector in registry.collectors:
        let metricType = parseMetricType(collector.typ)
        let help = parseMetricHelp(collector.help)
        let entriesPtr = addr entries
        collector.collect(
          proc(
              name: string,
              value: float64,
              labels, labelValues: openArray[string],
              timestamp: Time,
          ) {.gcsafe, raises: [].} =
            addMetricEntry(
              entriesPtr, metricType, help, name, value, labels, labelValues, timestamp
            )
        )
  entries

proc libp2pCollectMetrics*(lib: LibP2P): Future[Result[string, string]] {.ffi.} =
  var jsonText: string
  try:
    {.cast(gcsafe).}:
      jsonText = $collectRegistryMetrics(defaultRegistry).toJson()
  except CatchableError as e:
    return err("failed to serialize metrics: " & e.msg)
  ok(jsonText)

genBindings()

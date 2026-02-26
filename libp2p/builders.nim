# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

## This module contains a Switch Building helper.
runnableExamples:
  let switch = SwitchBuilder.new().withRng(rng).withAddresses(multiaddress)
    # etc
    .build()

{.push raises: [].}

import options, tables, chronos, chronicles, sequtils
import
  switch,
  peerid,
  peerinfo,
  stream/connection,
  multiaddress,
  crypto/crypto,
  transports/[transport, tcptransport, wstransport, quictransport, memorytransport],
  muxers/[muxer, mplex/mplex, yamux/yamux],
  protocols/[identify, secure/secure, secure/noise, rendezvous, kademlia],
  protocols/connectivity/[
    autonat/server,
    autonatv2/server,
    autonatv2/service,
    autonatv2/client,
    relay/relay,
    relay/client,
    relay/rtransport,
  ],
  connmanager,
  upgrademngrs/muxedupgrade,
  observedaddrmanager,
  autotls/service,
  nameresolving/nameresolver,
  errors,
  utility
import services/wildcardresolverservice

export
  switch, peerid, peerinfo, connection, multiaddress, crypto, errors, TLSPrivateKey,
  TLSCertificate, TLSFlags, ServerFlags

const MemoryAutoAddress* = memorytransport.MemoryAutoAddress

type
  TransportProvider* {.deprecated: "Use TransportBuilder instead".} =
    proc(upgr: Upgrade, privateKey: PrivateKey): Transport {.gcsafe, raises: [].}

  TransportBuilder* {.public.} =
    proc(config: TransportConfig): Transport {.gcsafe, raises: [].}

  TransportConfig* = ref object
    upgr*: Upgrade
    privateKey*: PrivateKey
    autotls*: Opt[AutotlsService]
    connManager*: ConnManager

  SecureProtocol* {.pure.} = enum
    Noise

  KadInfo = object
    config*: KadDHTConfig
    bootstrapNodes*: seq[(PeerId, seq[MultiAddress])]

  SwitchBuilder* = ref object
    privKey: Opt[PrivateKey]
    addresses: seq[MultiAddress]
    secureManagers: seq[SecureProtocol]
    muxers: seq[MuxerProvider]
    transports: seq[TransportBuilder]
    rng: ref HmacDrbgContext
    maxConnections: int
    maxIn: int
    sendSignedPeerRecord: bool
    maxOut: int
    maxConnsPerPeer: int
    protoVersion: string
    agentVersion: string
    nameResolver: NameResolver
    peerStoreCapacity: Opt[int]
    autonat: bool
    autonatV2ServerConfig: Opt[AutonatV2Config]
    autonatV2Client: AutonatV2Client
    autonatV2ServiceConfig: AutonatV2ServiceConfig
    autotls: Opt[AutotlsService]
    circuitRelay: Opt[Relay]
    rdv: Opt[RendezVous]
    kad: Opt[KadInfo]
    services: seq[Service]
    observedAddrManager: ObservedAddrManager
    enableWildcardResolver: bool

proc new*(T: type[SwitchBuilder]): T {.public.} =
  ## Creates a SwitchBuilder

  let address =
    MultiAddress.init("/ip4/127.0.0.1/tcp/0").expect("Should initialize to default")

  SwitchBuilder(
    privKey: Opt.none(PrivateKey),
    addresses: @[address],
    secureManagers: @[],
    maxConnections: MaxConnections,
    maxIn: -1,
    maxOut: -1,
    maxConnsPerPeer: MaxConnectionsPerPeer,
    protoVersion: ProtoVersion,
    agentVersion: AgentVersion,
    autotls: Opt.none(AutotlsService),
    circuitRelay: Opt.none(Relay),
    rdv: Opt.none(RendezVous),
    kad: Opt.none(KadInfo),
    enableWildcardResolver: true,
  )

proc withPrivateKey*(
    b: SwitchBuilder, privateKey: PrivateKey
): SwitchBuilder {.public.} =
  ## Set the private key of the switch. Will be used to
  ## generate a PeerId

  b.privKey = Opt.some(privateKey)
  b

proc withAddresses*(
    b: SwitchBuilder, addresses: seq[MultiAddress], enableWildcardResolver: bool = true
): SwitchBuilder {.public.} =
  ## | Set the listening addresses of the switch
  ## | Calling it multiple time will override the value
  b.addresses = addresses
  b.enableWildcardResolver = enableWildcardResolver
  b

proc withAddress*(
    b: SwitchBuilder, address: MultiAddress, enableWildcardResolver: bool = true
): SwitchBuilder {.public.} =
  ## | Set the listening address of the switch
  ## | Calling it multiple time will override the value
  b.withAddresses(@[address], enableWildcardResolver)

proc withSignedPeerRecord*(b: SwitchBuilder, sendIt = true): SwitchBuilder {.public.} =
  b.sendSignedPeerRecord = sendIt
  b

proc withMplex*(
    b: SwitchBuilder, inTimeout = 5.minutes, outTimeout = 5.minutes, maxChannCount = 200
): SwitchBuilder {.public.} =
  ## | Uses `Mplex <https://docs.libp2p.io/concepts/stream-multiplexing/#mplex>`_ as a multiplexer
  ## | `Timeout` is the duration after which a inactive connection will be closed
  proc newMuxer(conn: Connection): Muxer =
    Mplex.new(conn, inTimeout, outTimeout, maxChannCount)

  assert b.muxers.countIt(it.codec == MplexCodec) == 0, "Mplex build multiple times"
  b.muxers.add(MuxerProvider.new(newMuxer, MplexCodec))
  b

proc withYamux*(
    b: SwitchBuilder,
    maxChannCount: int = MaxChannelCount,
    windowSize: int = YamuxDefaultWindowSize,
    inTimeout: Duration = 5.minutes,
    outTimeout: Duration = 5.minutes,
): SwitchBuilder =
  proc newMuxer(conn: Connection): Muxer =
    Yamux.new(
      conn,
      maxChannCount = maxChannCount,
      windowSize = windowSize,
      inTimeout = inTimeout,
      outTimeout = outTimeout,
    )

  assert b.muxers.countIt(it.codec == YamuxCodec) == 0, "Yamux build multiple times"
  b.muxers.add(MuxerProvider.new(newMuxer, YamuxCodec))
  b

proc withNoise*(b: SwitchBuilder): SwitchBuilder {.public.} =
  b.secureManagers.add(SecureProtocol.Noise)
  b

proc withTransport*(
    b: SwitchBuilder, prov: TransportBuilder
): SwitchBuilder {.public.} =
  ## Use a custom transport
  runnableExamples:
    let switch = SwitchBuilder
      .new()
      .withTransport(
        proc(config: TransportConfig): Transport =
          TcpTransport.new(flags, config.upgr)
      )
      .build()
  b.transports.add(prov)
  b

proc withTransport*(
    b: SwitchBuilder, prov: TransportProvider
): SwitchBuilder {.deprecated: "Use TransportBuilder instead".} =
  ## Use a custom transport
  runnableExamples:
    let switch = SwitchBuilder
      .new()
      .withTransport(
        proc(upgr: Upgrade, privateKey: PrivateKey): Transport =
          TcpTransport.new(flags, upgr)
      )
      .build()
  let tBuilder: TransportBuilder = proc(config: TransportConfig): Transport =
    prov(config.upgr, config.privateKey)
  b.withTransport(tBuilder)

proc withTcpTransport*(
    b: SwitchBuilder, flags: set[ServerFlags] = {}
): SwitchBuilder {.public.} =
  b.withTransport(
    proc(config: TransportConfig): Transport =
      TcpTransport.new(flags, config.upgr)
  )

proc withWsTransport*(
    b: SwitchBuilder,
    tlsPrivateKey: TLSPrivateKey = nil,
    tlsCertificate: TLSCertificate = nil,
    tlsFlags: set[TLSFlags] = {},
    flags: set[ServerFlags] = {},
): SwitchBuilder =
  b.withTransport(
    proc(config: TransportConfig): Transport =
      WsTransport.new(
        config.upgr, tlsPrivateKey, tlsCertificate, config.autotls, tlsFlags, flags
      )
  )

proc withQuicTransport*(b: SwitchBuilder): SwitchBuilder {.public.} =
  b.withTransport(
    proc(config: TransportConfig): Transport =
      QuicTransport.new(config.upgr, config.privateKey, config.connManager)
  )

proc withMemoryTransport*(b: SwitchBuilder): SwitchBuilder {.public.} =
  b.withTransport(
    proc(config: TransportConfig): Transport =
      MemoryTransport.new(config.upgr)
  )

proc withRng*(b: SwitchBuilder, rng: ref HmacDrbgContext): SwitchBuilder {.public.} =
  b.rng = rng
  b

proc withMaxConnections*(
    b: SwitchBuilder, maxConnections: int
): SwitchBuilder {.public.} =
  ## Maximum concurrent connections of the switch. You should either use this, or
  ## `withMaxIn <#withMaxIn,SwitchBuilder,int>`_ & `withMaxOut<#withMaxOut,SwitchBuilder,int>`_
  b.maxConnections = maxConnections
  b

proc withMaxIn*(b: SwitchBuilder, maxIn: int): SwitchBuilder {.public.} =
  ## Maximum concurrent incoming connections. Should be used with `withMaxOut<#withMaxOut,SwitchBuilder,int>`_
  b.maxIn = maxIn
  b

proc withMaxOut*(b: SwitchBuilder, maxOut: int): SwitchBuilder {.public.} =
  ## Maximum concurrent outgoing connections. Should be used with `withMaxIn<#withMaxIn,SwitchBuilder,int>`_
  b.maxOut = maxOut
  b

proc withMaxConnsPerPeer*(
    b: SwitchBuilder, maxConnsPerPeer: int
): SwitchBuilder {.public.} =
  b.maxConnsPerPeer = maxConnsPerPeer
  b

proc withPeerStore*(b: SwitchBuilder, capacity: int): SwitchBuilder {.public.} =
  b.peerStoreCapacity = Opt.some(capacity)
  b

proc withProtoVersion*(
    b: SwitchBuilder, protoVersion: string
): SwitchBuilder {.public.} =
  b.protoVersion = protoVersion
  b

proc withAgentVersion*(
    b: SwitchBuilder, agentVersion: string
): SwitchBuilder {.public.} =
  b.agentVersion = agentVersion
  b

proc withNameResolver*(
    b: SwitchBuilder, nameResolver: NameResolver
): SwitchBuilder {.public.} =
  b.nameResolver = nameResolver
  b

proc withAutonat*(b: SwitchBuilder): SwitchBuilder =
  b.autonat = true
  b

proc withAutonatV2Server*(
    b: SwitchBuilder, config: AutonatV2Config = AutonatV2Config.new()
): SwitchBuilder =
  b.autonatV2ServerConfig = Opt.some(config)
  b

proc withAutonatV2*(
    b: SwitchBuilder, serviceConfig = AutonatV2ServiceConfig.new()
): SwitchBuilder =
  b.autonatV2Client = AutonatV2Client.new(b.rng)
  b.autonatV2ServiceConfig = serviceConfig
  b

when defined(libp2p_autotls_support):
  proc withAutotls*(
      b: SwitchBuilder, config: AutotlsConfig = AutotlsConfig.new()
  ): SwitchBuilder {.public.} =
    b.autotls = Opt.some(AutotlsService.new(config = config))
    b

proc withCircuitRelay*(b: SwitchBuilder, r: Relay = Relay.new()): SwitchBuilder =
  b.circuitRelay = Opt.some(r)
  b

proc withRendezVous*(b: SwitchBuilder, rdv: RendezVous): SwitchBuilder =
  var lrdv = rdv
  if rdv.isNil():
    lrdv = RendezVous.new()

  b.rdv = Opt.some(lrdv)
  b

proc withKademlia*(
    b: SwitchBuilder,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
): SwitchBuilder =
  b.kad = Opt.some(KadInfo(config: config, bootstrapNodes: bootstrapNodes))
  b

proc withServices*(b: SwitchBuilder, services: seq[Service]): SwitchBuilder =
  b.services = services
  b

proc withObservedAddrManager*(
    b: SwitchBuilder, observedAddrManager: ObservedAddrManager
): SwitchBuilder =
  b.observedAddrManager = observedAddrManager
  b

proc build*(b: SwitchBuilder): Switch {.raises: [LPError], public.} =
  if b.rng == nil: # newRng could fail
    raise newException(Defect, "Cannot initialize RNG")

  let pkRes = PrivateKey.random(b.rng[])
  let seckey = b.privKey.get(otherwise = pkRes.expect("Expected default Private Key"))

  if b.secureManagers.len == 0:
    debug "no secure managers defined. Adding noise by default"
    b.secureManagers.add(SecureProtocol.Noise)

  var secureManagerInstances: seq[Secure]
  if SecureProtocol.Noise in b.secureManagers:
    secureManagerInstances.add(Noise.new(b.rng, seckey).Secure)

  let peerInfo = PeerInfo.new(
    seckey, b.addresses, protoVersion = b.protoVersion, agentVersion = b.agentVersion
  )

  let identify =
    if b.observedAddrManager != nil:
      Identify.new(peerInfo, b.sendSignedPeerRecord, b.observedAddrManager)
    else:
      Identify.new(peerInfo, b.sendSignedPeerRecord)

  let
    connManager =
      ConnManager.new(b.maxConnsPerPeer, b.maxConnections, b.maxIn, b.maxOut)
    ms = MultistreamSelect.new()
    muxedUpgrade = MuxedUpgrade.new(b.muxers, secureManagerInstances, ms, connManager)

  b.autotls.withValue(autotlsService):
    b.services.add(autotlsService)

  let transports = block:
    var transports: seq[Transport]
    for tProvider in b.transports:
      transports.add(
        tProvider(
          TransportConfig(
            upgr: muxedUpgrade,
            privateKey: seckey,
            autotls: b.autotls,
            connManager: connManager,
          )
        )
      )
    transports

  if b.secureManagers.len == 0:
    b.secureManagers &= SecureProtocol.Noise

  if isNil(b.rng):
    b.rng = newRng()

  let peerStore = block:
    b.peerStoreCapacity.withValue(capacity):
      PeerStore.new(identify, capacity)
    else:
      PeerStore.new(identify)

  if b.enableWildcardResolver:
    b.services.add(WildcardAddressResolverService.new())

  if not isNil(b.autonatV2Client):
    b.services.add(
      AutonatV2Service.new(
        b.rng, client = b.autonatV2Client, config = b.autonatV2ServiceConfig
      )
    )

  let switch = newSwitch(
    peerInfo = peerInfo,
    transports = transports,
    secureManagers = secureManagerInstances,
    connManager = connManager,
    ms = ms,
    nameResolver = b.nameResolver,
    peerStore = peerStore,
    services = b.services,
  )

  switch.mount(identify)

  if not isNil(b.autonatV2Client):
    b.autonatV2Client.setup(switch)
    switch.mount(b.autonatV2Client)

  b.autonatV2ServerConfig.withValue(config):
    switch.mount(AutonatV2.new(switch, config = config))

  if b.autonat:
    switch.mount(Autonat.new(switch))

  b.circuitRelay.withValue(relay):
    if relay of RelayClient:
      switch.addTransport(RelayTransport.new(RelayClient(relay), muxedUpgrade))
    relay.setup(switch)
    switch.mount(relay)

  b.rdv.withValue(rdvService):
    rdvService.setup(switch)
    switch.mount(rdvService)

  b.kad.withValue(kadInfo):
    let kad = KadDHT.new(
      switch, bootstrapNodes = kadInfo.bootstrapNodes, config = kadInfo.config
    )
    switch.mount(kad)

  return switch

type TransportType* {.pure.} = enum
  QUIC
  TCP
  Memory

type MuxerType* {.pure.} = enum
  MPLEX
  YAMUX

proc newStandardSwitchBuilder*(
    privKey = Opt.none(PrivateKey),
    addrs: MultiAddress | seq[MultiAddress] = newSeq[MultiAddress](),
    transport: TransportType = TransportType.TCP,
    transportFlags: set[ServerFlags] = {},
    muxer: MuxerType = MuxerType.MPLEX,
    rng = newRng(),
    secureManagers: openArray[SecureProtocol] = [SecureProtocol.Noise],
    inTimeout: Duration = 5.minutes,
    outTimeout: Duration = 5.minutes,
    maxConnections = MaxConnections,
    maxIn = -1,
    maxOut = -1,
    maxConnsPerPeer = MaxConnectionsPerPeer,
    nameResolver = Opt.none(NameResolver),
    sendSignedPeerRecord = false,
    peerStoreCapacity = 1000,
): SwitchBuilder {.raises: [LPError], public.} =
  ## Helper for common switch configurations.
  var b = SwitchBuilder
    .new()
    .withRng(rng)
    .withSignedPeerRecord(sendSignedPeerRecord)
    .withMaxConnections(maxConnections)
    .withMaxIn(maxIn)
    .withMaxOut(maxOut)
    .withMaxConnsPerPeer(maxConnsPerPeer)
    .withPeerStore(capacity = peerStoreCapacity)
    .withNoise()

  privKey.withValue(pkey):
    b = b.withPrivateKey(pkey)

  nameResolver.withValue(nr):
    b = b.withNameResolver(nr)

  var addrs =
    when addrs is MultiAddress:
      @[addrs]
    else:
      addrs

  case transport
  of TransportType.QUIC:
    if addrs.len == 0:
      addrs = @[MultiAddress.init("/ip4/0.0.0.0/udp/0/quic-v1").tryGet()]
    b = b.withQuicTransport().withAddresses(addrs)
    return b # quic does not use a muxer
  of TransportType.TCP:
    if addrs.len == 0:
      addrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet()]
    b = b.withTcpTransport(transportFlags).withAddresses(addrs)
  of TransportType.Memory:
    if addrs.len == 0:
      addrs = @[MultiAddress.init(MemoryAutoAddress).tryGet()]
    b = b.withMemoryTransport().withAddresses(addrs)

  case muxer
  of MuxerType.MPLEX:
    b = b.withMplex(inTimeout, outTimeout)
  of MuxerType.YAMUX:
    b = b.withYamux(inTimeout = inTimeout, outTimeout = outTimeout)

  b

proc newStandardSwitch*(
    privKey = Opt.none(PrivateKey),
    addrs: MultiAddress | seq[MultiAddress] = newSeq[MultiAddress](),
    transport: TransportType = TransportType.TCP,
    transportFlags: set[ServerFlags] = {},
    muxer: MuxerType = MuxerType.MPLEX,
    rng = newRng(),
    secureManagers: openArray[SecureProtocol] = [SecureProtocol.Noise],
    inTimeout: Duration = 5.minutes,
    outTimeout: Duration = 5.minutes,
    maxConnections = MaxConnections,
    maxIn = -1,
    maxOut = -1,
    maxConnsPerPeer = MaxConnectionsPerPeer,
    nameResolver = Opt.none(NameResolver),
    sendSignedPeerRecord = false,
    peerStoreCapacity = 1000,
): Switch {.raises: [LPError], public.} =
  newStandardSwitchBuilder(
    privKey = privKey,
    addrs = addrs,
    transport = transport,
    transportFlags = transportFlags,
    muxer = muxer,
    rng = rng,
    secureManagers = secureManagers,
    inTimeout = inTimeout,
    outTimeout = outTimeout,
    maxConnections = maxConnections,
    maxIn = maxIn,
    maxOut = maxOut,
    maxConnsPerPeer = maxConnsPerPeer,
    nameResolver = nameResolver,
    sendSignedPeerRecord = sendSignedPeerRecord,
    peerStoreCapacity = peerStoreCapacity,
  )
  .build()

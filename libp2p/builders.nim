# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## This module contains a Switch Building helper.
{.push raises: [].}

import tables, chronos, chronicles, sequtils
import
  switch,
  peerid,
  peerinfo,
  peeraddrpolicy,
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
    relay/relay,
    relay/client,
    relay/rtransport,
  ],
  services/[identify_pusher, natservice, wildcardresolverservice],
  connmanager,
  upgrademngrs/muxedupgrade,
  observedaddrmanager,
  autotls/service,
  nameresolving/nameresolver,
  errors,
  utils/opt

export
  switch, peerid, peerinfo, peeraddrpolicy, connection, multiaddress, crypto, errors,
  TLSPrivateKey, TLSCertificate, TLSFlags, ServerFlags, connmanager.ConnectionLimits,
  connmanager.maxTotal, connmanager.maxInOut, natservice

const MemoryAutoAddress* = memorytransport.MemoryAutoAddress

type
  TransportBuilder* = proc(config: TransportConfig): Transport {.gcsafe, raises: [].}

  TransportConfig* = ref object
    upgr*: Upgrade
    privateKey*: PrivateKey
    autotls*: Opt[AutotlsService]
    connManager*: ConnManager
    rng*: Rng

  RelayReservationHandler* = proc(addresses: seq[MultiAddress]) {.gcsafe, raises: [].}

  SecureProtocol* {.pure.} = enum
    Noise

  KadInfo = object
    config*: KadDHTConfig
    bootstrapNodes*: seq[(PeerId, seq[MultiAddress])]

  SwitchBuilder* = ref object
    privKey: Opt[PrivateKey]
    addresses: seq[MultiAddress]
    announcedAddrs: seq[MultiAddress]
    secureManagers: seq[SecureProtocol]
    muxers: seq[MuxerProvider]
    transports: seq[TransportBuilder]
    rng: Rng
    maxConnsPerPeer: int
    limits: Opt[ConnectionLimits]
    watermark: Opt[WatermarkPolicy]
    scoring: PeerScoring
    sendSignedPeerRecord: bool
    protoVersion: string
    agentVersion: string
    nameResolver: NameResolver
    peerStoreCapacity: Opt[int]
    addressTtls: AddressConfidenceTtls
    autonatEnabled: bool
    autonatV2ServerConfig: Opt[AutonatV2Config]
    natConfig: Opt[NATConfig]
    natPortMapperFactory: PortMapperFactory
    autotlsConfig: Opt[AutotlsConfig]
    circuitRelay: Opt[Relay]
    rdvConfig: Opt[RendezVousConfig]
    kad: Opt[KadInfo]
    identifyPusherEnabled: bool
    observedAddrManager: ObservedAddrManager
    enableWildcardResolver: bool
    addressPolicy: PeerAddressPolicy

proc new*(T: type[SwitchBuilder]): T =
  ## Creates a SwitchBuilder

  SwitchBuilder(
    privKey: Opt.none(PrivateKey),
    addresses: @[],
    secureManagers: @[],
    maxConnsPerPeer: -1,
    limits: Opt.none(ConnectionLimits),
    watermark: Opt.none(WatermarkPolicy),
    scoring: PeerScoring(),
    protoVersion: ProtoVersion,
    agentVersion: AgentVersion,
    autonatV2ServerConfig: Opt.none(AutonatV2Config),
    natConfig: Opt.none(NATConfig),
    autotlsConfig: Opt.none(AutotlsConfig),
    circuitRelay: Opt.none(Relay),
    rdvConfig: Opt.none(RendezVousConfig),
    kad: Opt.none(KadInfo),
    identifyPusherEnabled: true,
    enableWildcardResolver: true,
    addressPolicy: defaultAddressPolicy,
    addressTtls: AddressConfidenceTtls(),
  )

proc withPrivateKey*(
    b: SwitchBuilder, privateKey: PrivateKey | Opt[PrivateKey]
): SwitchBuilder =
  ## Set the private key of the switch. Will be used to generate a PeerId

  b.privKey = toOpt(privateKey)
  b

proc withWildcardResolver*(b: SwitchBuilder, enabled: bool = true): SwitchBuilder =
  b.enableWildcardResolver = enabled
  b

proc withAddresses*(b: SwitchBuilder, addresses: seq[MultiAddress]): SwitchBuilder =
  ## Set the listening addresses of the switch
  b.addresses = addresses
  b

proc withAddress*(b: SwitchBuilder, address: MultiAddress): SwitchBuilder =
  ## Set the listening address of the switch
  b.withAddresses(@[address])

proc withAddresses*(
    b: SwitchBuilder, addresses: seq[MultiAddress], enableWildcardResolver: bool
): SwitchBuilder {.deprecated: "use withWildcardResolver()".} =
  ## Set the listening addresses of the switch
  b.addresses = addresses
  b.enableWildcardResolver = enableWildcardResolver
  b

proc withAddress*(
    b: SwitchBuilder, address: MultiAddress, enableWildcardResolver: bool
): SwitchBuilder {.deprecated: "use withWildcardResolver()".} =
  ## Set the listening address of the switch
  b.withAddresses(@[address], enableWildcardResolver)

proc withAnnouncedAddresses*(
    b: SwitchBuilder, addresses: seq[MultiAddress]
): SwitchBuilder =
  ## Set explicit addresses to advertise to peers, distinct from the
  ## switch's listening addresses. When non-empty, these replace the output
  ## of the address mapper chain (the `addressPolicy` filter is still applied).
  ## Use this to announce a public NAT-mapped address while binding locally.
  b.announcedAddrs = addresses
  b

proc withAnnouncedAddress*(b: SwitchBuilder, address: MultiAddress): SwitchBuilder =
  ## Set a single announced address. See `withAnnouncedAddresses`.
  b.withAnnouncedAddresses(@[address])

proc withSignedPeerRecord*(b: SwitchBuilder, sendIt = true): SwitchBuilder =
  b.sendSignedPeerRecord = sendIt
  b

proc withMplex*(
    b: SwitchBuilder, inTimeout = 5.minutes, outTimeout = 5.minutes, maxChannCount = 200
): SwitchBuilder =
  ## Uses `Mplex <https://docs.libp2p.io/concepts/stream-multiplexing/#mplex>`_ as a multiplexer
  ## `Timeout` is the duration after which a inactive connection will be closed
  proc newMuxer(conn: RawConn): Muxer =
    Mplex.new(conn, inTimeout, outTimeout, maxChannCount)

  doAssert b.muxers.countIt(it.codec == MplexCodec) == 0, "Mplex build multiple times"
  b.muxers.add(MuxerProvider.new(newMuxer, MplexCodec))
  b

proc withYamux*(
    b: SwitchBuilder,
    maxChannCount: int = MaxChannelCount,
    windowSize: int = YamuxDefaultWindowSize,
    inTimeout: Duration = 5.minutes,
    outTimeout: Duration = 5.minutes,
): SwitchBuilder =
  proc newMuxer(conn: RawConn): Muxer =
    Yamux.new(
      conn,
      maxChannCount = maxChannCount,
      windowSize = windowSize,
      inTimeout = inTimeout,
      outTimeout = outTimeout,
    )

  doAssert b.muxers.countIt(it.codec == YamuxCodec) == 0, "Yamux build multiple times"
  b.muxers.add(MuxerProvider.new(newMuxer, YamuxCodec))
  b

proc withNoise*(b: SwitchBuilder): SwitchBuilder =
  b.secureManagers.add(SecureProtocol.Noise)
  b

proc withTransport*(b: SwitchBuilder, prov: TransportBuilder): SwitchBuilder =
  ## Use a custom transport
  b.transports.add(prov)
  b

proc withTcpTransport*(b: SwitchBuilder, flags: set[ServerFlags] = {}): SwitchBuilder =
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
        config.upgr,
        tlsPrivateKey,
        tlsCertificate,
        config.autotls,
        rng = config.rng,
        tlsFlags = tlsFlags,
        flags = flags,
      )
  )

proc withQuicTransport*(b: SwitchBuilder): SwitchBuilder =
  b.withTransport(
    proc(config: TransportConfig): Transport =
      QuicTransport.new(config.upgr, config.privateKey, config.connManager)
  )

proc withMemoryTransport*(b: SwitchBuilder): SwitchBuilder =
  b.withTransport(
    proc(config: TransportConfig): Transport =
      MemoryTransport.new(config.upgr, config.rng)
  )

proc withRng*(b: SwitchBuilder, rng: Rng): SwitchBuilder =
  b.rng = rng
  b

proc withConnectionLimits*(b: SwitchBuilder, limits: ConnectionLimits): SwitchBuilder =
  ## Set the connection limits for the switch. Construct `limits` via
  ## `ConnectionLimits.maxTotal` for a shared cap or `ConnectionLimits.maxInOut`
  ## for independent per-direction caps.
  b.limits = Opt.some(limits)
  b

proc withMaxConnections*(b: SwitchBuilder, maxConnections: int): SwitchBuilder =
  ## Maximum concurrent connections of the switch. You should either use this,
  ## or `withMaxInOut <#withMaxInOut,SwitchBuilder,int,int>`_.
  b.limits = Opt.some(ConnectionLimits.maxTotal(maxConnections))
  b

proc withMaxInOut*(b: SwitchBuilder, maxIn: int, maxOut: int): SwitchBuilder =
  ## Maximum concurrent incoming and outgoing connections.
  b.limits = Opt.some(ConnectionLimits.maxInOut(maxIn, maxOut))
  b

proc withMaxConnsPerPeer*(b: SwitchBuilder, maxConnsPerPeer: int): SwitchBuilder =
  b.maxConnsPerPeer = maxConnsPerPeer
  b

proc withWatermarkPolicy*(
    b: SwitchBuilder,
    lowWater: int,
    highWater: int,
    gracePeriod: Duration = 0.minutes,
    silencePeriod: Duration = 10.seconds,
): SwitchBuilder =
  ## Enable hi/lo watermark connection management.
  ## When connected peers exceed `highWater`, the connection manager trims
  ## down to `lowWater`, skipping peers within `gracePeriod` and protected peers.
  ## Can be combined with `withMaxConnections`/`withMaxInOut` to apply both
  ## a hard semaphore cap and active trimming simultaneously.
  doAssert lowWater > 0, "lowWater must be > 0"
  doAssert highWater > lowWater, "highWater must be > lowWater"
  b.watermark = Opt.some(
    WatermarkPolicy(
      lowWater: lowWater,
      highWater: highWater,
      gracePeriod: gracePeriod,
      silencePeriod: silencePeriod,
    )
  )
  b

proc withPeerScoring*(
    b: SwitchBuilder, scoring: PeerScoring = PeerScoring()
): SwitchBuilder =
  ## Configure peer scoring parameters.
  doAssert scoring.decayResolution > 0.seconds, "decayResolution must be > 0"
  b.scoring = scoring
  b

proc withPeerStore*(b: SwitchBuilder, capacity: int): SwitchBuilder =
  b.peerStoreCapacity = Opt.some(capacity)
  b

proc withAddressConfidenceTtls*(
    b: SwitchBuilder, ttls: AddressConfidenceTtls
): SwitchBuilder =
  ## Override the per-confidence TTLs used to expire peer addresses.
  b.addressTtls = ttls
  b

proc withProtoVersion*(b: SwitchBuilder, protoVersion: string): SwitchBuilder =
  b.protoVersion = protoVersion
  b

proc withAgentVersion*(b: SwitchBuilder, agentVersion: string): SwitchBuilder =
  b.agentVersion = agentVersion
  b

proc withNameResolver*(b: SwitchBuilder, nameResolver: NameResolver): SwitchBuilder =
  b.nameResolver = nameResolver
  b

proc withAutonat*(b: SwitchBuilder, enabled: bool = true): SwitchBuilder =
  b.autonatEnabled = enabled
  b

proc withAutonatV2Server*(
    b: SwitchBuilder, config: AutonatV2Config = AutonatV2Config.new()
): SwitchBuilder =
  b.autonatV2ServerConfig = Opt.some(config)
  b

proc mergeInto(dst: var NATConfig, src: NATConfig) =
  src.portMapping.withValue(v):
    doAssert dst.portMapping.isNone, "withNAT: portMapping configured more than once"
    dst.portMapping = Opt.some(v)
  src.reachability.withValue(v):
    doAssert dst.reachability.isNone, "withNAT: reachability configured more than once"
    dst.reachability = Opt.some(v)
  src.holePunching.withValue(v):
    doAssert dst.holePunching.isNone, "withNAT: holePunching configured more than once"
    dst.holePunching = Opt.some(v)

proc withNAT*(
    b: SwitchBuilder, config: NATConfig, portMapperFactory: PortMapperFactory = nil
): SwitchBuilder =
  ## Build ``config`` with `upnpConfig`/`natPmpConfig`/`explicitIpConfig`/`autonatConfig`/`holePunchingConfig`.
  ## May be called repeatedly for distinct concerns; setting one concern twice is a programmer error.
  var merged = b.natConfig.get(NATConfig())
  merged.mergeInto(config)
  b.natConfig = Opt.some(merged)
  if not portMapperFactory.isNil:
    b.natPortMapperFactory = portMapperFactory
  b

proc withAutonatV2*(
    b: SwitchBuilder,
    serviceConfig: AutonatV2ServiceConfig = AutonatV2ServiceConfig.new(),
): SwitchBuilder {.
    deprecated:
      "use withNAT(autonatConfig(AutonatV2, v2ServiceConfig = Opt.some(serviceConfig)))"
.} =
  b.withNAT(autonatConfig(AutonatV2, v2ServiceConfig = Opt.some(serviceConfig)))

proc withHolePunching*(
    b: SwitchBuilder, maxNumRelays: int, onReservationHandler: RelayReservationHandler
): SwitchBuilder {.
    deprecated: "use withNAT(holePunchingConfig(maxNumRelays, onReservationHandler))"
.} =
  b.withNAT(holePunchingConfig(maxNumRelays, onReservationHandler))

proc withAutotls*(
    b: SwitchBuilder, config: AutotlsConfig = AutotlsConfig.new()
): SwitchBuilder =
  b.autotlsConfig = Opt.some(config)
  b

proc withCircuitRelay*(b: SwitchBuilder, r: Relay = Relay.new()): SwitchBuilder =
  if r.isNil:
    b.circuitRelay = Opt.none(Relay)
  else:
    b.circuitRelay = Opt.some(r)

  b

proc withRendezVous*(
    b: SwitchBuilder, config: RendezVousConfig = RendezVousConfig.new()
): SwitchBuilder =
  b.rdvConfig = Opt.some(config)
  b

proc withKademlia*(
    b: SwitchBuilder,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
): SwitchBuilder =
  b.kad = Opt.some(KadInfo(config: config, bootstrapNodes: bootstrapNodes))
  b

proc withIdentifyPusher*(b: SwitchBuilder, enabled: bool = true): SwitchBuilder =
  ## When enabled, the IdentifyPush protocol is mounted on the
  ## switch and an `IdentifyPusher` service tracks which connected peers
  ## advertise IdentifyPush, broadcasting our updated `PeerInfo` to all
  ## tracked peers whenever it changes.
  b.identifyPusherEnabled = enabled
  b

proc withObservedAddrManager*(
    b: SwitchBuilder, observedAddrManager: ObservedAddrManager
): SwitchBuilder =
  b.observedAddrManager = observedAddrManager
  b

proc withAddressPolicy*(
    b: SwitchBuilder, addressPolicy: PeerAddressPolicy
): SwitchBuilder =
  ## Applies a single address visibility policy across local address
  ## announcements and all discovery/storage paths configured by the builder.
  b.addressPolicy = addressPolicy
  b

proc withPrivateAddressFilter*(b: SwitchBuilder): SwitchBuilder =
  ## Filter private (RFC1918/link-local) addresses from all peer address
  ## announcements and incoming peer address records. When enabled:
  ## - Our node will not announce private addresses to the network
  ## - Private addresses received from other peers are discarded
  ## Circuit relay and DNS addresses are never filtered.
  b.withAddressPolicy(publicRoutableAddressPolicy)

proc buildSwitch(b: SwitchBuilder): Switch {.raises: [LPError].} =
  if isNil(b.rng):
    b.rng = newRng()

  if b.rng == nil: # newRng could fail
    raise newException(Defect, "Cannot initialize RNG")

  let seckey = b.privKey.valueOr:
    PrivateKey.random(b.rng).expect("Expected default Private Key")

  if b.secureManagers.len == 0:
    debug "no secure managers defined. Adding noise by default"
    b.secureManagers.add(SecureProtocol.Noise)

  var secureManagerInstances: seq[Secure]
  if SecureProtocol.Noise in b.secureManagers:
    secureManagerInstances.add(Noise.new(b.rng, seckey).Secure)

  let peerInfo = PeerInfo.new(
    seckey,
    b.addresses,
    protoVersion = b.protoVersion,
    agentVersion = b.agentVersion,
    addressPolicy = b.addressPolicy,
    announcedAddrs = b.announcedAddrs,
  )

  let identify =
    if b.observedAddrManager != nil:
      Identify.new(peerInfo, b.sendSignedPeerRecord, b.observedAddrManager)
    else:
      Identify.new(peerInfo, b.sendSignedPeerRecord)

  var peerStore = block:
    b.peerStoreCapacity.withValue(capacity):
      PeerStore.new(identify, capacity, b.addressTtls)
    else:
      PeerStore.new(identify, addressTtls = b.addressTtls)
  peerStore.addressPolicy = b.addressPolicy

  var connManager = ConnManager.new(
    maxConnsPerPeer = b.maxConnsPerPeer,
    limits = b.limits,
    watermark = b.watermark,
    scoring = b.scoring,
  )
  connManager.peerStore = peerStore

  let ms = MultistreamSelect.new()
  let muxedUpgrade = MuxedUpgrade.new(b.muxers, secureManagerInstances, ms, connManager)

  var services: seq[Service]
  var autotlsOpt = Opt.none(AutotlsService)
  b.autotlsConfig.withValue(config):
    let autotlsService = AutotlsService.new(b.rng, config)
    autotlsOpt = Opt.some(autotlsService)
    services.add(autotlsService)

  var transports: seq[Transport]
  for tProvider in b.transports:
    transports.add(
      tProvider(
        TransportConfig(
          upgr: muxedUpgrade,
          privateKey: seckey,
          autotls: autotlsOpt,
          connManager: connManager,
          rng: b.rng,
        )
      )
    )

  let dialer =
    Dialer.new(peerInfo.peerId, connManager, peerStore, transports, ms, b.nameResolver)

  let switch = Switch(
    peerInfo: peerInfo,
    ms: ms,
    transports: transports,
    connManager: connManager,
    peerStore: peerStore,
    dialer: dialer,
    nameResolver: b.nameResolver,
    rng: b.rng,
    muxedUpgrade: muxedUpgrade,
    services: services,
  )

  return switch

proc setupServices(b: SwitchBuilder, switch: Switch) {.raises: [LPError].} =
  if b.enableWildcardResolver:
    switch.services.add(WildcardAddressResolverService.new())

  b.natConfig.withValue(natCfg):
    switch.services.add(NATService.new(natCfg, b.rng, b.natPortMapperFactory))

  if b.identifyPusherEnabled:
    switch.services.add(IdentifyPusher.new())

  for service in switch.services:
    service.setup(switch)

proc mountProtocols(b: SwitchBuilder, switch: Switch) {.raises: [LPError].} =
  if not switch.peerStore.identify.isNil:
    switch.mount(switch.peerStore.identify)

  b.rdvConfig.withValue(rdvCfg):
    let rend = RendezVous.new(b.rng, rdvCfg)
    rend.setup(switch)
    switch.mount(rend)

  b.autonatV2ServerConfig.withValue(config):
    switch.mount(AutonatV2.new(switch, config = config))

  if b.autonatEnabled:
    switch.mount(Autonat.new(switch))

  b.circuitRelay.withValue(relay):
    if relay of RelayClient:
      switch.addTransport(RelayTransport.new(RelayClient(relay), switch.muxedUpgrade))
    relay.setup(switch)
    switch.mount(relay)

  b.kad.withValue(kadInfo):
    var config = kadInfo.config
    config.addressPolicy = b.addressPolicy
    let kad = KadDHT.new(
      switch, bootstrapNodes = kadInfo.bootstrapNodes, config = config, rng = b.rng
    )
    switch.mount(kad)

proc build*(b: SwitchBuilder): Switch {.raises: [LPError].} =
  var switch = b.buildSwitch()
  b.setupServices(switch)
  b.mountProtocols(switch)

  return switch

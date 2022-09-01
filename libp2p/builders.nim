# Nim-Libp2p
# Copyright (c) 2022 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

## This module contains a Switch Building helper.
runnableExamples:
  let switch =
   SwitchBuilder.new()
   .withRng(rng)
   .withAddresses(multiaddress)
   # etc
   .build()

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import
  options, tables, chronos, chronicles, sequtils,
  switch, peerid, peerinfo, stream/connection, multiaddress,
  crypto/crypto, transports/[transport, tcptransport],
  muxers/[muxer, mplex/mplex, yamux/yamux],
  protocols/[identify, secure/secure, secure/noise, autonat],
  protocols/relay/[relay, client, rtransport],
  connmanager, upgrademngrs/muxedupgrade,
  nameresolving/nameresolver,
  errors, utility

export
  switch, peerid, peerinfo, connection, multiaddress, crypto, errors

type
  TransportProvider* {.public.} = proc(upgr: Upgrade): Transport {.gcsafe, raises: [Defect].}

  SecureProtocol* {.pure.} = enum
    Noise,
    Secio {.deprecated.}

  SwitchBuilder* = ref object
    privKey: Option[PrivateKey]
    addresses: seq[MultiAddress]
    secureManagers: seq[SecureProtocol]
    muxers: seq[MuxerProvider]
    transports: seq[TransportProvider]
    rng: ref HmacDrbgContext
    maxConnections: int
    maxIn: int
    sendSignedPeerRecord: bool
    maxOut: int
    maxConnsPerPeer: int
    protoVersion: string
    agentVersion: string
    nameResolver: NameResolver
    peerStoreCapacity: Option[int]
    autonat: bool
    circuitRelay: Relay

proc new*(T: type[SwitchBuilder]): T {.public.} =
  ## Creates a SwitchBuilder

  let address = MultiAddress
  .init("/ip4/127.0.0.1/tcp/0")
  .expect("Should initialize to default")

  SwitchBuilder(
    privKey: none(PrivateKey),
    addresses: @[address],
    secureManagers: @[],
    maxConnections: MaxConnections,
    maxIn: -1,
    maxOut: -1,
    maxConnsPerPeer: MaxConnectionsPerPeer,
    protoVersion: ProtoVersion,
    agentVersion: AgentVersion)

proc withPrivateKey*(b: SwitchBuilder, privateKey: PrivateKey): SwitchBuilder {.public.} =
  ## Set the private key of the switch. Will be used to
  ## generate a PeerId

  b.privKey = some(privateKey)
  b

proc withAddress*(b: SwitchBuilder, address: MultiAddress): SwitchBuilder {.public.} =
  ## | Set the listening address of the switch
  ## | Calling it multiple time will override the value

  b.addresses = @[address]
  b

proc withAddresses*(b: SwitchBuilder, addresses: seq[MultiAddress]): SwitchBuilder {.public.} =
  ## | Set the listening addresses of the switch
  ## | Calling it multiple time will override the value

  b.addresses = addresses
  b

proc withSignedPeerRecord*(b: SwitchBuilder, sendIt = true): SwitchBuilder {.public.} =
  b.sendSignedPeerRecord = sendIt
  b

proc withMplex*(
    b: SwitchBuilder,
    inTimeout = 5.minutes,
    outTimeout = 5.minutes,
    maxChannCount = 200): SwitchBuilder {.public.} =
  ## | Uses `Mplex <https://docs.libp2p.io/concepts/stream-multiplexing/#mplex>`_ as a multiplexer
  ## | `Timeout` is the duration after which a inactive connection will be closed
  proc newMuxer(conn: Connection): Muxer =
    Mplex.new(
      conn,
      inTimeout,
      outTimeout,
      maxChannCount)

  assert b.muxers.countIt(it.codec == MplexCodec) == 0, "Mplex build multiple times"
  b.muxers.add(MuxerProvider.new(newMuxer, MplexCodec))
  b

proc withYamux*(b: SwitchBuilder): SwitchBuilder =
  proc newMuxer(conn: Connection): Muxer = Yamux.new(conn)

  assert b.muxers.countIt(it.codec == YamuxCodec) == 0, "Yamux build multiple times"
  b.muxers.add(MuxerProvider.new(newMuxer, YamuxCodec))
  b

proc withNoise*(b: SwitchBuilder): SwitchBuilder {.public.} =
  b.secureManagers.add(SecureProtocol.Noise)
  b

proc withTransport*(b: SwitchBuilder, prov: TransportProvider): SwitchBuilder {.public.} =
  ## Use a custom transport
  runnableExamples:
    let switch =
      SwitchBuilder.new()
      .withTransport(proc(upgr: Upgrade): Transport = TcpTransport.new(flags, upgr))
      .build()
  b.transports.add(prov)
  b

proc withTcpTransport*(b: SwitchBuilder, flags: set[ServerFlags] = {}): SwitchBuilder {.public.} =
  b.withTransport(proc(upgr: Upgrade): Transport = TcpTransport.new(flags, upgr))

proc withRng*(b: SwitchBuilder, rng: ref HmacDrbgContext): SwitchBuilder {.public.} =
  b.rng = rng
  b

proc withMaxConnections*(b: SwitchBuilder, maxConnections: int): SwitchBuilder {.public.} =
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

proc withMaxConnsPerPeer*(b: SwitchBuilder, maxConnsPerPeer: int): SwitchBuilder {.public.} =
  b.maxConnsPerPeer = maxConnsPerPeer
  b

proc withPeerStore*(b: SwitchBuilder, capacity: int): SwitchBuilder {.public.} =
  b.peerStoreCapacity = some(capacity)
  b

proc withProtoVersion*(b: SwitchBuilder, protoVersion: string): SwitchBuilder {.public.} =
  b.protoVersion = protoVersion
  b

proc withAgentVersion*(b: SwitchBuilder, agentVersion: string): SwitchBuilder {.public.} =
  b.agentVersion = agentVersion
  b

proc withNameResolver*(b: SwitchBuilder, nameResolver: NameResolver): SwitchBuilder {.public.} =
  b.nameResolver = nameResolver
  b

proc withAutonat*(b: SwitchBuilder): SwitchBuilder =
  b.autonat = true
  b

proc withCircuitRelay*(b: SwitchBuilder, r: Relay = Relay.new()): SwitchBuilder =
  b.circuitRelay = r
  b

proc build*(b: SwitchBuilder): Switch
  {.raises: [Defect, LPError], public.} =

  if b.rng == nil: # newRng could fail
    raise newException(Defect, "Cannot initialize RNG")

  let pkRes = PrivateKey.random(b.rng[])
  let
    seckey = b.privKey.get(otherwise = pkRes.expect("Expected default Private Key"))

  var
    secureManagerInstances: seq[Secure]
  if SecureProtocol.Noise in b.secureManagers:
    secureManagerInstances.add(Noise.new(b.rng, seckey).Secure)

  let
    peerInfo = PeerInfo.new(
      seckey,
      b.addresses,
      protoVersion = b.protoVersion,
      agentVersion = b.agentVersion)

  let
    identify = Identify.new(peerInfo, b.sendSignedPeerRecord)
    connManager = ConnManager.new(b.maxConnsPerPeer, b.maxConnections, b.maxIn, b.maxOut)
    ms = MultistreamSelect.new()
    muxedUpgrade = MuxedUpgrade.new(identify, b.muxers, secureManagerInstances, connManager, ms)

  let
    transports = block:
      var transports: seq[Transport]
      for tProvider in b.transports:
        transports.add(tProvider(muxedUpgrade))
      transports

  if b.secureManagers.len == 0:
    b.secureManagers &= SecureProtocol.Noise

  if isNil(b.rng):
    b.rng = newRng()

  let peerStore =
    if isSome(b.peerStoreCapacity):
      PeerStore.new(b.peerStoreCapacity.get())
    else:
      PeerStore.new()

  let switch = newSwitch(
    peerInfo = peerInfo,
    transports = transports,
    identity = identify,
    secureManagers = secureManagerInstances,
    connManager = connManager,
    ms = ms,
    nameResolver = b.nameResolver,
    peerStore = peerStore)

  if b.autonat:
    let autonat = Autonat.new(switch)
    switch.mount(autonat)

  if not isNil(b.circuitRelay):
    if b.circuitRelay of RelayClient:
      switch.addTransport(RelayTransport.new(RelayClient(b.circuitRelay), muxedUpgrade))
    b.circuitRelay.setup(switch)
    switch.mount(b.circuitRelay)

  return switch

proc newStandardSwitch*(
  privKey = none(PrivateKey),
  addrs: MultiAddress | seq[MultiAddress] = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
  secureManagers: openArray[SecureProtocol] = [
      SecureProtocol.Noise,
    ],
  transportFlags: set[ServerFlags] = {},
  rng = newRng(),
  inTimeout: Duration = 5.minutes,
  outTimeout: Duration = 5.minutes,
  maxConnections = MaxConnections,
  maxIn = -1,
  maxOut = -1,
  maxConnsPerPeer = MaxConnectionsPerPeer,
  nameResolver: NameResolver = nil,
  sendSignedPeerRecord = false,
  peerStoreCapacity = 1000): Switch
  {.raises: [Defect, LPError], public.} =
  ## Helper for common switch configurations.

  if SecureProtocol.Secio in secureManagers:
      quit("Secio is deprecated!") # use of secio is unsafe

  let addrs = when addrs is MultiAddress: @[addrs] else: addrs
  var b = SwitchBuilder
    .new()
    .withAddresses(addrs)
    .withRng(rng)
    .withSignedPeerRecord(sendSignedPeerRecord)
    .withMaxConnections(maxConnections)
    .withMaxIn(maxIn)
    .withMaxOut(maxOut)
    .withMaxConnsPerPeer(maxConnsPerPeer)
    .withPeerStore(capacity=peerStoreCapacity)
    .withMplex(inTimeout, outTimeout)
    .withTcpTransport(transportFlags)
    .withNameResolver(nameResolver)
    .withNoise()

  if privKey.isSome():
    b = b.withPrivateKey(privKey.get())

  b.build()

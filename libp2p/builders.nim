## Nim-Libp2p
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import
  options, tables, chronos, chronicles, bearssl,
  switch, peerid, peerinfo, stream/connection, multiaddress,
  crypto/crypto, transports/[transport, tcptransport],
  muxers/[muxer, mplex/mplex],
  protocols/[identify, secure/secure, secure/noise],
  connmanager, upgrademngrs/muxedupgrade,
  nameresolving/nameresolver,
  errors

export
  switch, peerid, peerinfo, connection, multiaddress, crypto, errors

type
  TransportProvider* = proc(upgr: Upgrade): Transport {.gcsafe, raises: [Defect].}

  SecureProtocol* {.pure.} = enum
    Noise,
    Secio {.deprecated.}

  MplexOpts = object
    enable: bool
    newMuxer: MuxerConstructor

  SwitchBuilder* = ref object
    privKey: Option[PrivateKey]
    addresses: seq[MultiAddress]
    secureManagers: seq[SecureProtocol]
    mplexOpts: MplexOpts
    transports: seq[TransportProvider]
    rng: ref BrHmacDrbgContext
    maxConnections: int
    maxIn: int
    maxOut: int
    maxConnsPerPeer: int
    protoVersion: string
    agentVersion: string
    nameResolver: NameResolver

proc new*(T: type[SwitchBuilder]): T =

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

proc withPrivateKey*(b: SwitchBuilder, privateKey: PrivateKey): SwitchBuilder =
  b.privKey = some(privateKey)
  b

proc withAddress*(b: SwitchBuilder, address: MultiAddress): SwitchBuilder =
  b.addresses = @[address]
  b

proc withAddresses*(b: SwitchBuilder, addresses: seq[MultiAddress]): SwitchBuilder =
  b.addresses = addresses
  b


proc withMplex*(b: SwitchBuilder, inTimeout = 5.minutes, outTimeout = 5.minutes): SwitchBuilder =
  proc newMuxer(conn: Connection): Muxer =
    Mplex.new(
      conn,
      inTimeout = inTimeout,
      outTimeout = outTimeout)

  b.mplexOpts = MplexOpts(
    enable: true,
    newMuxer: newMuxer,
  )

  b

proc withNoise*(b: SwitchBuilder): SwitchBuilder =
  b.secureManagers.add(SecureProtocol.Noise)
  b

proc withTransport*(b: SwitchBuilder, prov: TransportProvider): SwitchBuilder =
  b.transports.add(prov)
  b

proc withTcpTransport*(b: SwitchBuilder, flags: set[ServerFlags] = {}): SwitchBuilder =
  b.withTransport(proc(upgr: Upgrade): Transport = TcpTransport.new(flags, upgr))

proc withRng*(b: SwitchBuilder, rng: ref BrHmacDrbgContext): SwitchBuilder =
  b.rng = rng
  b

proc withMaxConnections*(b: SwitchBuilder, maxConnections: int): SwitchBuilder =
  b.maxConnections = maxConnections
  b

proc withMaxIn*(b: SwitchBuilder, maxIn: int): SwitchBuilder =
  b.maxIn = maxIn
  b

proc withMaxOut*(b: SwitchBuilder, maxOut: int): SwitchBuilder =
  b.maxOut = maxOut
  b

proc withMaxConnsPerPeer*(b: SwitchBuilder, maxConnsPerPeer: int): SwitchBuilder =
  b.maxConnsPerPeer = maxConnsPerPeer
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

proc build*(b: SwitchBuilder): Switch
  {.raises: [Defect, LPError].} =

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
    muxers = block:
      var muxers: Table[string, MuxerProvider]
      if b.mplexOpts.enable:
        muxers[MplexCodec] = MuxerProvider.new(b.mplexOpts.newMuxer, MplexCodec)
      muxers

  let
    identify = Identify.new(peerInfo)
    connManager = ConnManager.new(b.maxConnsPerPeer, b.maxConnections, b.maxIn, b.maxOut)
    ms = MultistreamSelect.new()
    muxedUpgrade = MuxedUpgrade.new(identify, muxers, secureManagerInstances, connManager, ms)

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

  let switch = newSwitch(
    peerInfo = peerInfo,
    transports = transports,
    identity = identify,
    muxers = muxers,
    secureManagers = secureManagerInstances,
    connManager = connManager,
    ms = ms,
    nameResolver = b.nameResolver)

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
  nameResolver: NameResolver = nil): Switch
  {.raises: [Defect, LPError].} =
  if SecureProtocol.Secio in secureManagers:
      quit("Secio is deprecated!") # use of secio is unsafe

  let addrs = when addrs is MultiAddress: @[addrs] else: addrs
  var b = SwitchBuilder
    .new()
    .withAddresses(addrs)
    .withRng(rng)
    .withMaxConnections(maxConnections)
    .withMaxIn(maxIn)
    .withMaxOut(maxOut)
    .withMaxConnsPerPeer(maxConnsPerPeer)
    .withMplex(inTimeout, outTimeout)
    .withTcpTransport(transportFlags)
    .withNameResolver(nameResolver)
    .withNoise()

  if privKey.isSome():
    b = b.withPrivateKey(privKey.get())

  b.build()

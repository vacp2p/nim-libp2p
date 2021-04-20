import
  options, tables, chronos, bearssl,
  switch, peerid, peerinfo, stream/connection, multiaddress,
  crypto/crypto, transports/[transport, tcptransport],
  muxers/[muxer, mplex/mplex],
  protocols/[identify, secure/secure, secure/noise]

export
  switch, peerid, peerinfo, connection, multiaddress, crypto

type
  SecureProtocol* {.pure.} = enum
    Noise,
    Secio {.deprecated.}

  TcpTransportOpts = object
    enable: bool
    flags: set[ServerFlags]

  MplexOpts = object
    enable: bool
    newMuxer: MuxerConstructor

  SwitchBuilder* = ref object
    privKey: Option[PrivateKey]
    address: MultiAddress
    secureManagers: seq[SecureProtocol]
    mplexOpts: MplexOpts
    tcpTransportOpts: TcpTransportOpts
    rng: ref BrHmacDrbgContext
    maxConnections: int
    maxIn: int
    maxOut: int
    maxConnsPerPeer: int
    protoVersion: string
    agentVersion: string

proc new*(T: type[SwitchBuilder]): T =
  SwitchBuilder(
    privKey: none(PrivateKey),
    address: MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    secureManagers: @[],
    tcpTransportOpts: TcpTransportOpts(),
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
  b.address = address
  b

proc withMplex*(b: SwitchBuilder, inTimeout = 5.minutes, outTimeout = 5.minutes): SwitchBuilder =
  proc newMuxer(conn: Connection): Muxer =
    Mplex.init(
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

proc withTcpTransport*(b: SwitchBuilder, flags: set[ServerFlags] = {}): SwitchBuilder =
  b.tcpTransportOpts.enable = true
  b.tcpTransportOpts.flags = flags
  b

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

proc build*(b: SwitchBuilder): Switch =
  if b.rng == nil: # newRng could fail
    raise (ref CatchableError)(msg: "Cannot initialize RNG")

  let
    seckey = b.privKey.get(otherwise = PrivateKey.random(b.rng[]).tryGet())

  var
    secureManagerInstances: seq[Secure]
  if SecureProtocol.Noise in b.secureManagers:
    secureManagerInstances.add(newNoise(b.rng, seckey).Secure)

  let
    peerInfo = block:
      var info = PeerInfo.init(seckey, [b.address])
      info.protoVersion = b.protoVersion
      info.agentVersion = b.agentVersion
      info

  let
    muxers = block:
      var muxers: Table[string, MuxerProvider]
      if b.mplexOpts.enable:
        muxers.add(MplexCodec, newMuxerProvider(b.mplexOpts.newMuxer, MplexCodec))
      muxers

  let
    identify = newIdentify(peerInfo)

  let
    transports = block:
      var transports: seq[Transport]
      if b.tcpTransportOpts.enable:
        transports.add(Transport(TcpTransport.init(b.tcpTransportOpts.flags)))
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
    maxConnections = b.maxConnections,
    maxIn = b.maxIn,
    maxOut = b.maxOut,
    maxConnsPerPeer = b.maxConnsPerPeer)

  return switch

proc newStandardSwitch*(privKey = none(PrivateKey),
                        address = MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
                        secureManagers: openarray[SecureProtocol] = [
                            SecureProtocol.Noise,
                          ],
                        transportFlags: set[ServerFlags] = {},
                        rng = newRng(),
                        inTimeout: Duration = 5.minutes,
                        outTimeout: Duration = 5.minutes,
                        maxConnections = MaxConnections,
                        maxIn = -1,
                        maxOut = -1,
                        maxConnsPerPeer = MaxConnectionsPerPeer): Switch =
  if SecureProtocol.Secio in secureManagers:
      quit("Secio is deprecated!") # use of secio is unsafe

  var b = SwitchBuilder
    .new()
    .withAddress(address)
    .withRng(rng)
    .withMaxConnections(maxConnections)
    .withMaxIn(maxIn)
    .withMaxOut(maxOut)
    .withMaxConnsPerPeer(maxConnsPerPeer)
    .withMplex(inTimeout, outTimeout)
    .withTcpTransport(transportFlags)
    .withNoise()

  if privKey.isSome():
    b = b.withPrivateKey(privKey.get())

  b.build()

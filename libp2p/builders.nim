import
  options, tables, chronos, bearssl,
  switch, peerid, peerinfo, stream/connection, multiaddress,
  crypto/crypto, transports/[transport, tcptransport],
  muxers/[muxer, mplex/mplex],
  protocols/[identify, secure/secure, secure/noise],
  connmanager

export
  switch, peerid, peerinfo, connection, multiaddress, crypto

type
  SecureProtocol* {.pure.} = enum
    Noise,
    Secio {.deprecated.}

  SwitchBuilder* {.byref.} = object
    privKey: Option[PrivateKey]
    address: MultiAddress
    secureManagers: seq[SecureProtocol]
    tcpTransportFlags: Option[set[ServerFlags]]
    rng: ref BrHmacDrbgContext
    inTimeout: Duration
    outTimeout: Duration
    maxConnections: int
    maxIn: int
    maxOut: int
    maxConnsPerPeer: int
    protoVersion: Option[string]
    agentVersion: Option[string]

proc init*(_: type[SwitchBuilder]): SwitchBuilder =
  SwitchBuilder(
    privKey: none(PrivateKey),
    address: MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    secureManagers: @[],
    tcpTransportFlags: block:
      let flags: set[ServerFlags] = {}
      some(flags),
    rng: newRng(),
    inTimeout: 5.minutes,
    outTimeout: 5.minutes,
    maxConnections: MaxConnections,
    maxIn: -1,
    maxOut: -1,
    maxConnsPerPeer: MaxConnectionsPerPeer,
    protoVersion: none(string),
    agentVersion: none(string))

# so I tried using var inpit and return but did not work...
# as in proc privateKey*(builder: var SwitchBuilder, privateKey: PrivateKey): var SwitchBuilder =
# so in nim we are stuck with this hardly efficient way and hopey compiler figures it out.. heh
# maybe {.byref.} works.... I would not bet on it but let's use it.

proc withPrivateKey*(builder: SwitchBuilder, privateKey: PrivateKey): SwitchBuilder =
  var b = builder
  b.privKey = some(privateKey)
  b

proc withAddress*(builder: SwitchBuilder, address: MultiAddress): SwitchBuilder =
  var b = builder
  b.address = address
  b

proc withSecureManager*(builder: SwitchBuilder, secureManager: SecureProtocol): SwitchBuilder =
  var b = builder
  b.secureManagers &= secureManager
  b

proc withTcpTransport*(builder: SwitchBuilder, flags: set[ServerFlags] = {}): SwitchBuilder =
  var b = builder
  b.tcpTransportFlags = some(flags)
  b

proc withRng*(builder: SwitchBuilder, rng: ref BrHmacDrbgContext): SwitchBuilder =
  var b = builder
  b.rng = rng
  b

proc withInTimeout*(builder: SwitchBuilder, inTimeout: Duration): SwitchBuilder =
  var b = builder
  b.inTimeout = inTimeout
  b

proc withOutTimeout*(builder: SwitchBuilder, outTimeout: Duration): SwitchBuilder =
  var b = builder
  b.outTimeout = outTimeout
  b

proc withMaxConnections*(builder: SwitchBuilder, maxConnections: int): SwitchBuilder =
  var b = builder
  b.maxConnections = maxConnections
  b

proc withMaxIn*(builder: SwitchBuilder, maxIn: int): SwitchBuilder =
  var b = builder
  b.maxIn = maxIn
  b

proc withMaxOut*(builder: SwitchBuilder, maxOut: int): SwitchBuilder =
  var b = builder
  b.maxOut = maxOut
  b

proc withMaxConnsPerPeer*(builder: SwitchBuilder, maxConnsPerPeer: int): SwitchBuilder =
  var b = builder
  b.maxConnsPerPeer = maxConnsPerPeer
  b

proc withProtoVersion*(builder: SwitchBuilder, protoVersion: string): SwitchBuilder =
  var b = builder
  b.protoVersion = some(protoVersion)
  b

proc withAgentVersion*(builder: SwitchBuilder, agentVersion: string): SwitchBuilder =
  var b = builder
  b.agentVersion = some(agentVersion)
  b

proc build*(builder: SwitchBuilder): Switch =
  var b = builder

  let
    inTimeout = b.inTimeout
    outTimeout = b.outTimeout

  proc createMplex(conn: Connection): Muxer =
    Mplex.init(
      conn,
      inTimeout = inTimeout,
      outTimeout = outTimeout)

  if b.rng == nil: # newRng could fail
    raise (ref CatchableError)(msg: "Cannot initialize RNG")

  let
    seckey = b.privKey.get(otherwise = PrivateKey.random(b.rng[]).tryGet())
    peerInfo = block:
      let info = PeerInfo.init(seckey, [b.address])
      if b.protoVersion.isSome():
        info.protoVersion = b.protoVersion.get()
      if b.agentVersion.isSome():
        info.agentVersion = b.agentVersion.get()
      info
    mplexProvider = newMuxerProvider(createMplex, MplexCodec)
    transports = block:
      var transports: seq[Transport]
      if b.tcpTransportFlags.isSome():
        transports &= Transport(TcpTransport.init(b.tcpTransportFlags.get()))
      transports
    muxers = {MplexCodec: mplexProvider}.toTable
    identify = newIdentify(peerInfo)

  if b.secureManagers.len == 0:
    b.secureManagers &= SecureProtocol.Noise

  var
    secureManagerInstances: seq[Secure]
  for sec in b.secureManagers:
    case sec
    of SecureProtocol.Noise:
      secureManagerInstances &= newNoise(b.rng, seckey).Secure
    of SecureProtocol.Secio:
      quit("Secio is deprecated!") # use of secio is unsafe

  let switch = newSwitch(
    peerInfo,
    transports,
    identify,
    muxers,
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
  var b = SwitchBuilder
    .init()
    .withAddress(address)
    .withRng(rng)
    .withInTimeout(inTimeout)
    .withOutTimeout(outTimeout)
    .withMaxConnections(maxConnections)
    .withMaxIn(maxIn)
    .withMaxOut(maxOut)
    .withMaxConnsPerPeer(maxConnsPerPeer)
    .withTcpTransport(transportFlags)

  if privKey.isSome():
    b = b.withPrivateKey(privKey.get())

  for sm in secureManagers:
    b = b.withSecureManager(sm)

  b.build()

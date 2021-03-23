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
    bprivKey: Option[PrivateKey]
    baddress: MultiAddress
    bsecureManagers: seq[SecureProtocol]
    btransportFlags: set[ServerFlags]
    brng: ref BrHmacDrbgContext
    binTimeout: Duration
    boutTimeout: Duration
    bmaxConnections: int
    bmaxIn: int
    bmaxOut: int
    bmaxConnsPerPeer: int
    bprotoVersion: Option[string]
    bagentVersion: Option[string]

proc init*(_: type[SwitchBuilder]): SwitchBuilder =
  SwitchBuilder(
    bprivKey: none(PrivateKey),
    baddress: MultiAddress.init("/ip4/127.0.0.1/tcp/0").tryGet(),
    bsecureManagers: @[],
    btransportFlags: {},
    brng: newRng(),
    binTimeout: 5.minutes,
    boutTimeout: 5.minutes,
    bmaxConnections: MaxConnections,
    bmaxIn: -1,
    bmaxOut: -1,
    bmaxConnsPerPeer: MaxConnectionsPerPeer,
    bprotoVersion: none(string),
    bagentVersion: none(string))

# so I tried using var inpit and return but did not work...
# as in proc privateKey*(builder: var SwitchBuilder, privateKey: PrivateKey): var SwitchBuilder =
# so in nim we are stuck with this hardly efficient way and hopey compiler figures it out.. heh
# maybe {.byref.} works.... I would not bet on it but let's use it.

proc privateKey*(builder: SwitchBuilder, privateKey: PrivateKey): SwitchBuilder =
  var b = builder
  b.bprivKey = some(privateKey)
  b

proc address*(builder: SwitchBuilder, address: MultiAddress): SwitchBuilder =
  var b = builder
  b.baddress = address
  b

proc secureManager*(builder: SwitchBuilder, secureManager: SecureProtocol): SwitchBuilder =
  var b = builder
  b.bsecureManagers &= secureManager
  b

proc transportFlag*(builder: SwitchBuilder, flag: ServerFlags): SwitchBuilder =
  var b = builder
  b.btransportFlags = b.btransportFlags + {flag}
  b

proc rng*(builder: SwitchBuilder, rng: ref BrHmacDrbgContext): SwitchBuilder =
  var b = builder
  b.brng = rng
  b

proc inTimeout*(builder: SwitchBuilder, inTimeout: Duration): SwitchBuilder =
  var b = builder
  b.binTimeout = inTimeout
  b

proc outTimeout*(builder: SwitchBuilder, outTimeout: Duration): SwitchBuilder =
  var b = builder
  b.boutTimeout = outTimeout
  b

proc maxConnections*(builder: SwitchBuilder, maxConnections: int): SwitchBuilder =
  var b = builder
  b.bmaxConnections = maxConnections
  b

proc maxIn*(builder: SwitchBuilder, maxIn: int): SwitchBuilder =
  var b = builder
  b.bmaxIn = maxIn
  b

proc maxOut*(builder: SwitchBuilder, maxOut: int): SwitchBuilder =
  var b = builder
  b.bmaxOut = maxOut
  b

proc maxConnsPerPeer*(builder: SwitchBuilder, maxConnsPerPeer: int): SwitchBuilder =
  var b = builder
  b.bmaxConnsPerPeer = maxConnsPerPeer
  b

proc protoVersion*(builder: SwitchBuilder, protoVersion: string): SwitchBuilder =
  var b = builder
  b.bprotoVersion = some(protoVersion)
  b

proc agentVersion*(builder: SwitchBuilder, agentVersion: string): SwitchBuilder =
  var b = builder
  b.bagentVersion = some(agentVersion)
  b

proc build*(builder: SwitchBuilder): Switch =
  var b = builder

  let
    inTimeout = b.binTimeout
    outTimeout = b.boutTimeout

  proc createMplex(conn: Connection): Muxer =
    Mplex.init(
      conn,
      inTimeout = inTimeout,
      outTimeout = outTimeout)

  if b.brng == nil: # newRng could fail
    raise (ref CatchableError)(msg: "Cannot initialize RNG")

  let
    seckey = b.bprivKey.get(otherwise = PrivateKey.random(b.brng[]).tryGet())
    peerInfo = block:
      let info = PeerInfo.init(seckey, [b.baddress])
      if b.bprotoVersion.isSome():
        info.protoVersion = b.bprotoVersion.get()
      if b.bagentVersion.isSome():
        info.agentVersion = b.bagentVersion.get()
      info
    mplexProvider = newMuxerProvider(createMplex, MplexCodec)
    transports = @[Transport(TcpTransport.init(b.btransportFlags))]
    muxers = {MplexCodec: mplexProvider}.toTable
    identify = newIdentify(peerInfo)

  if b.bsecureManagers.len == 0:
    b.bsecureManagers &= SecureProtocol.Noise

  var
    secureManagerInstances: seq[Secure]
  for sec in b.bsecureManagers:
    case sec
    of SecureProtocol.Noise:
      secureManagerInstances &= newNoise(b.brng, seckey).Secure
    of SecureProtocol.Secio:
      quit("Secio is deprecated!") # use of secio is unsafe

  let switch = newSwitch(
    peerInfo,
    transports,
    identify,
    muxers,
    secureManagers = secureManagerInstances,
    maxConnections = b.bmaxConnections,
    maxIn = b.bmaxIn,
    maxOut = b.bmaxOut,
    maxConnsPerPeer = b.bmaxConnsPerPeer)

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
    .address(address)
    .rng(rng)
    .inTimeout(inTimeout)
    .outTimeout(outTimeout)
    .maxConnections(maxConnections)
    .maxIn(maxIn)
    .maxOut(maxOut)
    .maxConnsPerPeer(maxConnsPerPeer)

  if privKey.isSome():
    b = b.privateKey(privKey.get())

  for sm in secureManagers:
    b = b.secureManager(sm)

  for flag in transportFlags:
    b = b.transportFlag(flag)

  b.build()

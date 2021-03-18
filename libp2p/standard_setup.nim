import
  options, tables, chronos, bearssl,
  switch, peerid, peerinfo, stream/connection, multiaddress,
  crypto/crypto, transports/[transport, tcptransport],
  muxers/[muxer, mplex/mplex],
  protocols/[identify, secure/secure, secure/noise],
  upgrademngrs/[upgrade, muxedupgrade], connmanager

export
  switch, peerid, peerinfo, connection, multiaddress, crypto

type
  SecureProtocol* {.pure.} = enum
    Noise,
    Secio {.deprecated.}

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
  proc createMplex(conn: Connection): Muxer =
    Mplex.init(
      conn,
      inTimeout = inTimeout,
      outTimeout = outTimeout)

  if rng == nil: # newRng could fail
    raise (ref CatchableError)(msg: "Cannot initialize RNG")

  let
    seckey = privKey.get(otherwise = PrivateKey.random(rng[]).tryGet())
    peerInfo = PeerInfo.init(seckey, [address])

  var
    secureManagerInstances: seq[Secure]

  for sec in secureManagers:
    case sec
    of SecureProtocol.Noise:
      secureManagerInstances &= newNoise(rng, seckey).Secure
    of SecureProtocol.Secio:
      quit("Secio is deprecated!") # use of secio is unsafe

  let
    mplexProvider = newMuxerProvider(createMplex, MplexCodec)
    ms = newMultistream()
    identify = newIdentify(peerInfo)
    muxers = {MplexCodec: mplexProvider}.toTable
    connManager = ConnManager.init(maxConnsPerPeer, maxConnections, maxIn, maxOut)
    muxedUpgrade = MuxedUpgrade.init(identify, muxers, secureManagerInstances, connManager, ms)
    transports = @[Transport(TcpTransport.init(transportFlags, muxedUpgrade))]

  let switch = newSwitch(
    peerInfo,
    transports,
    identify,
    muxers,
    secureManagers = secureManagerInstances,
    connManager = connManager,
    ms = ms)

  return switch

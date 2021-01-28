import
  options, tables, chronos, bearssl,
  switch, peerid, peerinfo, stream/connection, multiaddress,
  crypto/crypto, transports/[transport, tcptransport],
  muxers/[muxer, mplex/mplex],
  protocols/[identify, secure/secure]

import
  protocols/secure/noise,
  protocols/secure/secio

export
  switch, peerid, peerinfo, connection, multiaddress, crypto

type
  SecureProtocol* {.pure.} = enum
    Noise,
    Secio

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
    mplexProvider = newMuxerProvider(createMplex, MplexCodec)
    transports = @[Transport(TcpTransport.init(transportFlags))]
    muxers = {MplexCodec: mplexProvider}.toTable
    identify = newIdentify(peerInfo)

  var
    secureManagerInstances: seq[Secure]
  for sec in secureManagers:
    case sec
    of SecureProtocol.Noise:
      secureManagerInstances &= newNoise(rng, seckey).Secure
    of SecureProtocol.Secio:
      secureManagerInstances &= newSecio(rng, seckey).Secure

  let switch = newSwitch(
    peerInfo,
    transports,
    identify,
    muxers,
    secureManagers = secureManagerInstances,
    maxConnections = maxConnections,
    maxIn = maxIn,
    maxOut = maxOut,
    maxConnsPerPeer = maxConnsPerPeer)

  return switch

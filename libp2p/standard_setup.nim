# compile time options here
const
  libp2p_pubsub_sign {.booldefine.} = true
  libp2p_pubsub_verify {.booldefine.} = true

import
  options, tables, chronos, bearssl,
  switch, peerid, peerinfo, stream/connection, multiaddress,
  crypto/crypto, transports/[transport, tcptransport],
  muxers/[muxer, mplex/mplex, mplex/types],
  protocols/[identify, secure/secure],
  protocols/pubsub/[pubsub, gossipsub, floodsub],
  protocols/pubsub/rpc/message

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
                        triggerSelf = false,
                        gossip = false,
                        secureManagers: openarray[SecureProtocol] = [
                            # array cos order matters
                            SecureProtocol.Secio,
                            SecureProtocol.Noise,
                          ],
                        verifySignature = libp2p_pubsub_verify,
                        sign = libp2p_pubsub_sign,
                        transportFlags: set[ServerFlags] = {},
                        msgIdProvider: MsgIdProvider = defaultMsgIdProvider,
                        rng = newRng(),
                        inTimeout: Duration = 5.minutes,
                        outTimeout: Duration = 5.minutes): Switch =
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

  let pubSub = if gossip:
                  newPubSub(GossipSub,
                            peerInfo = peerInfo,
                            triggerSelf = triggerSelf,
                            verifySignature = verifySignature,
                            sign = sign,
                            msgIdProvider = msgIdProvider).PubSub
               else:
                  newPubSub(FloodSub,
                            peerInfo = peerInfo,
                            triggerSelf = triggerSelf,
                            verifySignature = verifySignature,
                            sign = sign,
                            msgIdProvider = msgIdProvider).PubSub

  newSwitch(
    peerInfo,
    transports,
    identify,
    muxers,
    secureManagers = secureManagerInstances,
    pubSub = some(pubSub))

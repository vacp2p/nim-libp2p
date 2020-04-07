import
  options, tables
import core,
       muxers/mplex/mplex,
       transports/tcptransport,
       protocols/[pubsub/floodsub, pubsub/gossipsub, secure/secio]

export core

proc newStandardSwitch*(privKey = none(PrivateKey),
                        address = MultiAddress.init("/ip4/127.0.0.1/tcp/0"),
                        triggerSelf = false,
                        gossip = false): Switch =
  proc createMplex(conn: Connection): Muxer =
    result = newMplex(conn)

  let
    seckey = privKey.get(otherwise = PrivateKey.random(ECDSA))
    peerInfo = PeerInfo.init(seckey, [address])
    mplexProvider = newMuxerProvider(createMplex, MplexCodec)
    transports = @[Transport(newTransport(TcpTransport))]
    muxers = {MplexCodec: mplexProvider}.toTable
    identify = newIdentify(peerInfo)
    secureManagers = {SecioCodec: Secure(newSecio seckey)}.toTable
    pubSub = if gossip: PubSub newPubSub(GossipSub, peerInfo, triggerSelf)
             else: PubSub newPubSub(FloodSub, peerInfo, triggerSelf)

  result = newSwitch(peerInfo,
                     transports,
                     identify,
                     muxers,
                     secureManagers = secureManagers,
                     pubSub = some(pubSub))

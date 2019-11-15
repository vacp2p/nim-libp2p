import options, tables
import chronos
import ../../libp2p/[switch,
                     peer,
                     connection,
                     multiaddress,
                     peerinfo,
                     muxers/muxer,
                     crypto/crypto,
                     muxers/mplex/mplex,
                     muxers/mplex/types,
                     protocols/identify,
                     transports/transport,
                     transports/tcptransport,
                     protocols/secure/secure,
                     protocols/secure/secio,
                     protocols/pubsub/pubsub,
                     protocols/pubsub/gossipsub,
                     protocols/pubsub/floodsub]

proc createMplex(conn: Connection): Muxer =
  result = newMplex(conn)

proc createNode*(privKey: Option[PrivateKey] = none(PrivateKey), 
                 address: string = "/ip4/127.0.0.1/tcp/0",
                 triggerSelf: bool = false,
                 gossip: bool = false): Switch = 
  var peerInfo: PeerInfo
  var seckey = privKey
  if privKey.isNone:
    seckey = some(PrivateKey.random(RSA))

  peerInfo.peerId = some(PeerID.init(seckey.get()))
  peerInfo.addrs.add(Multiaddress.init(address))

  let mplexProvider = newMuxerProvider(createMplex, MplexCodec)
  let transports = @[Transport(newTransport(TcpTransport))]
  let muxers = [(MplexCodec, mplexProvider)].toTable()
  let identify = newIdentify(peerInfo)
  let secureManagers = [(SecioCodec, Secure(newSecio(seckey.get())))].toTable()
  
  var pubSub: Option[PubSub]
  if gossip:
    pubSub = some(PubSub(newPubSub(GossipSub, peerInfo, triggerSelf)))
  else:
    pubSub = some(PubSub(newPubSub(FloodSub, peerInfo, triggerSelf)))

  result = newSwitch(peerInfo,
                     transports,
                     identify,
                     muxers,
                     secureManagers = secureManagers,
                     pubSub = pubSub)

proc generateNodes*(num: Natural, gossip: bool = false): seq[Switch] =
  for i in 0..<num:
    result.add(createNode(gossip = gossip))

proc subscribeNodes*(nodes: seq[Switch]) {.async.} =
  var pending: seq[Future[void]]
  for dialer in nodes:
    for node in nodes:
      if dialer.peerInfo.peerId != node.peerInfo.peerId:
        pending.add(dialer.subscribeToPeer(node.peerInfo))
        await sleepAsync(100.millis)

  await allFutures(pending)

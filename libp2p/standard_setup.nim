# compile time options here
const
  libp2p_secure {.strdefine.} = ""

import
  options, tables,
  switch, peer, peerinfo, connection, multiaddress,
  crypto/crypto, transports/[transport, tcptransport],
  muxers/[muxer, mplex/mplex, mplex/types],
  protocols/[identify, secure/secure],
  protocols/pubsub/[pubsub, gossipsub, floodsub]

when libp2p_secure == "noise":
  import protocols/secure/noise
else:
  import protocols/secure/secio

export
  switch, peer, peerinfo, connection, multiaddress, crypto

proc newStandardSwitch*(privKey = none(PrivateKey),
                        address = MultiAddress.init("/ip4/127.0.0.1/tcp/0"),
                        triggerSelf = false,
                        gossip = false,
                        verifySignature = false): Switch =
  proc createMplex(conn: Connection): Muxer =
    result = newMplex(conn)

  let
    seckey = privKey.get(otherwise = PrivateKey.random(ECDSA))
    peerInfo = PeerInfo.init(seckey, [address])
    mplexProvider = newMuxerProvider(createMplex, MplexCodec)
    transports = @[Transport(newTransport(TcpTransport))]
    muxers = {MplexCodec: mplexProvider}.toTable
    identify = newIdentify(peerInfo)
  when libp2p_secure == "noise":
    let secureManagers = {NoiseCodec: newNoise(seckey).Secure}.toTable
  else:
    let secureManagers = {SecioCodec: newSecio(seckey).Secure}.toTable
  let pubSub = if gossip:
                 PubSub newPubSub(GossipSub, peerInfo, triggerSelf, verifySignature)
               else:
                 PubSub newPubSub(FloodSub, peerInfo, triggerSelf, verifySignature)

  result = newSwitch(peerInfo,
                     transports,
                     identify,
                     muxers,
                     secureManagers = secureManagers,
                     pubSub = some(pubSub))


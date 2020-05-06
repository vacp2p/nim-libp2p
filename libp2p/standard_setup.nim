# compile time options here
const
  libp2p_secure {.strdefine.} = ""
  libp2p_pubsub_sign {.booldefine.} = true
  libp2p_pubsub_verify {.booldefine.} = true

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
                        verifySignature = libp2p_pubsub_verify,
                        sign = libp2p_pubsub_sign): Switch =
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
                 PubSub newPubSub(GossipSub,
                                  peerInfo = peerInfo,
                                  triggerSelf = triggerSelf,
                                  verifySignature = verifySignature,
                                  sign = sign)
               else:
                 PubSub newPubSub(FloodSub,
                                  peerInfo = peerInfo,
                                  triggerSelf = triggerSelf,
                                  verifySignature = verifySignature,
                                  sign = sign)

  result = newSwitch(peerInfo,
                     transports,
                     identify,
                     muxers,
                     secureManagers = secureManagers,
                     pubSub = some(pubSub))

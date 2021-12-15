{.used.}

import options, bearssl
import chronos
import ../libp2p/crypto/crypto,
       ../libp2p/peerinfo,
       ../libp2p/peerid

import ./helpers

suite "PeerInfo":
  test "Should init with private key":
    let seckey = PrivateKey.random(ECDSA, rng[]).get()
    var peerInfo = PeerInfo.new(seckey)
    var peerId = PeerId.init(seckey).get()

    check peerId == peerInfo.peerId
    check seckey.getPublicKey().get() == peerInfo.publicKey

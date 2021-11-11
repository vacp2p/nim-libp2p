{.used.}

import options, bearssl
import chronos
import ../libp2p/crypto/crypto,
       ../libp2p/peerinfo,
       ../libp2p/peerid,
       ../libp2p/routing_record

import ./helpers

suite "PeerInfo":
  test "Should init with private key":
    let seckey = PrivateKey.random(ECDSA, rng[]).get()
    var peerInfo = PeerInfo.new(seckey)
    var peerId = PeerID.init(seckey).get()

    check peerId == peerInfo.peerId
    check seckey.getPublicKey().get() == peerInfo.publicKey
  
  test "Signed peer record":
    let
      seckey = PrivateKey.random(rng[]).tryGet()
      peerId = PeerID.init(seckey).get()
      multiAddresses = @[MultiAddress.init("/ip4/0.0.0.0/tcp/24").tryGet(), MultiAddress.init("/ip4/0.0.0.0/tcp/25").tryGet()]
      peerInfo = PeerInfo.new(seckey, multiAddresses)
    
    let
      env = peerInfo.signedPeerRecord.get()
      rec = PeerRecord.decode(env.payload()).tryGet()
    
    # Check envelope fields
    check:
      env.publicKey == peerInfo.publicKey
      env.domain == EnvelopeDomain
      env.payloadType == EnvelopePayloadType

    # Check payload (routing record)
    check:
      rec.peerId == peerId
      rec.seqNo > 0
      rec.addresses.len == 2
      rec.addresses[0].address == multiAddresses[0]
      rec.addresses[1].address == multiAddresses[1]

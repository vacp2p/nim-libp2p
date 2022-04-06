{.used.}

import options, bearssl
import chronos, stew/byteutils
import ../libp2p/crypto/crypto,
       ../libp2p/multicodec,
       ../libp2p/peerinfo,
       ../libp2p/peerid,
       ../libp2p/routing_record

import ./helpers

suite "PeerInfo":
  test "Should init with private key":
    let seckey = PrivateKey.random(ECDSA, rng[]).get()
    var peerInfo = PeerInfo.new(seckey)
    var peerId = PeerId.init(seckey).get()

    check peerId == peerInfo.peerId
    check seckey.getPublicKey().get() == peerInfo.publicKey
  
  test "Signed peer record":
    const
      ExpectedDomain = $multiCodec("libp2p-peer-record")
      ExpectedPayloadType = @[(byte) 0x03, (byte) 0x01]
    
    let
      seckey = PrivateKey.random(rng[]).tryGet()
      peerId = PeerID.init(seckey).get()
      multiAddresses = @[MultiAddress.init("/ip4/0.0.0.0/tcp/24").tryGet(), MultiAddress.init("/ip4/0.0.0.0/tcp/25").tryGet()]
      peerInfo = PeerInfo.new(seckey, multiAddresses)
    
    let
      env = peerInfo.signedPeerRecord.envelope
      rec = PeerRecord.decode(env.payload()).tryGet()
    
    # Check envelope fields
    check:
      env.publicKey == peerInfo.publicKey
      env.domain == ExpectedDomain
      env.payloadType == ExpectedPayloadType

    # Check payload (routing record)
    check:
      rec.peerId == peerId
      rec.seqNo > 0
      rec.addresses.len == 2
      rec.addresses[0].address == multiAddresses[0]
      rec.addresses[1].address == multiAddresses[1]

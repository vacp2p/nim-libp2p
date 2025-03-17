import unittest2

import ../../../libp2p/transports/tls/certificate
import ../../../libp2p/crypto/crypto
import ../../../libp2p/peerid

suite "Certificate Tests":
  test "Generate with DER ecoding":    
    let schemes = @[Ed25519, Secp256k1, ECDSA]
    for scheme in schemes:
      var rng = newRng()
      let keypair = KeyPair.random(scheme, rng[]).tryGet()
      let peerId = PeerId.init(keypair.pubkey).tryGet()

      let (certBytes, _) = generate(keypair, EncodingFormat.DER)
      let cert = parse(certBytes)

      let parsedPeerId = PeerId.init(PublicKey.init(cert.extension.publicKey).tryGet).tryGet()
      check parsedPeerId == peerId

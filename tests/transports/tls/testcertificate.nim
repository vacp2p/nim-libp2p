import unittest2

import ../../../libp2p/transports/tls/certificate
import ../../../libp2p/crypto/crypto
import ../../../libp2p/peerid

suite "Certificate Tests":
  test "sanity check":
    var rng = newRng()

    # Generate an Ed25519 keypair
    let keypair = KeyPair.random(Secp256k1, rng[]).tryGet()
    let peerId = PeerId.init(keypair.pubkey).tryGet()

    let (certBytes, _) = generate(keypair, EncodingFormat.DER)
    let cert = parse(certBytes)
    let ext = cert.extension

    let parsedPeerId = PeerId.init(PublicKey.init(ext.publicKey).tryGet).tryGet()
    check parsedPeerId == peerId

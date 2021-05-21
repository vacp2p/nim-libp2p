## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
import unittest2, bearssl
import ../libp2p/crypto/[crypto, secp]
import nimcrypto/utils

when defined(nimHasUsed): {.used.}

let rng = newRng()

suite "Secp256k1 testing suite":
  const TestsCount = 20

  test "Private key serialize/deserialize test":
    for i in 0..<TestsCount:
      var rkey1, rkey2: SkPrivateKey
      var skey2 = newSeq[byte](256)
      var key = SkPrivateKey.random(rng[])
      var skey1 = key.getBytes()
      check:
        key.toBytes(skey2).expect("bytes len") > 0
      check:
        rkey1.init(skey1).isOk == true
        rkey2.init(skey2).isOk == true
      var rkey3 = SkPrivateKey.init(skey1).expect("private key")
      var rkey4 = SkPrivateKey.init(skey2).expect("private key")
      check:
        rkey1 == key
        rkey2 == key
        rkey3 == key
        rkey4 == key
  test "Public key serialize/deserialize test":
    for i in 0..<TestsCount:
      var rkey1, rkey2: SkPublicKey
      var skey2 = newSeq[byte](256)
      var pair = SkKeyPair.random(rng[])
      var skey1 = pair.pubkey.getBytes()
      check:
        pair.pubkey.toBytes(skey2).expect("bytes len") > 0
        rkey1.init(skey1).isOk == true
        rkey2.init(skey2).isOk == true
      var rkey3 = SkPublicKey.init(skey1).expect("public key")
      var rkey4 = SkPublicKey.init(skey2).expect("public key")
      check:
        rkey1 == pair.pubkey
        rkey2 == pair.pubkey
        rkey3 == pair.pubkey
        rkey4 == pair.pubkey
  test "Generate/Sign/Serialize/Deserialize/Verify test":
    var message = "message to sign"
    for i in 0..<TestsCount:
      var kp = SkKeyPair.random(rng[])
      var sig = kp.seckey.sign(message)
      var sersk = kp.seckey.getBytes()
      var serpk = kp.pubkey.getBytes()
      var sersig = sig.getBytes()
      discard SkPrivateKey.init(sersk).expect("private key")
      var pubkey = SkPublicKey.init(serpk).expect("public key")
      var csig = SkSignature.init(sersig).expect("signature")
      check csig.verify(message, pubkey) == true
      var error = csig.getBytes()
      error[^1] = not error[^1]
      csig = SkSignature.init(error).expect("signature")
      check csig.verify(message, pubkey) == false

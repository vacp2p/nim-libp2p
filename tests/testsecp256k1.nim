## Nim-Libp2p
## Copyright (c) 2018 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.
import unittest
import ../libp2p/crypto/secp
import nimcrypto/utils

when defined(nimHasUsed): {.used.}

suite "Secp256k1 testing suite":
  const TestsCount = 20
  test "Private key serialize/deserialize test":
    for i in 0..<TestsCount:
      var rkey1, rkey2: SecpPrivateKey
      var skey2 = newSeq[byte](256)
      var key = SecpPrivateKey.random().expect("random key")
      var skey1 = key.getBytes()
      check:
        key.toBytes(skey2).expect("bytes len") > 0
      check:
        rkey1.init(skey1).isOk == true
        rkey2.init(skey2).isOk == true
      var rkey3 = SecpPrivateKey.init(skey1).expect("private key")
      var rkey4 = SecpPrivateKey.init(skey2).expect("private key")
      check:
        rkey1 == key
        rkey2 == key
        rkey3 == key
        rkey4 == key
      rkey1.clear()
      rkey2.clear()
      check:
        not rkey1.verify()
        not rkey2.verify()
  test "Public key serialize/deserialize test":
    for i in 0..<TestsCount:
      var rkey1, rkey2: SecpPublicKey
      var skey2 = newSeq[byte](256)
      var pair = SecpKeyPair.random().expect("random key pair")
      var skey1 = pair.pubkey.getBytes()
      check:
        pair.pubkey.toBytes(skey2).expect("bytes len") > 0
        rkey1.init(skey1).isOk == true
        rkey2.init(skey2).isOk == true
      var rkey3 = SecpPublicKey.init(skey1).expect("public key")
      var rkey4 = SecpPublicKey.init(skey2).expect("public key")
      check:
        rkey1 == pair.pubkey
        rkey2 == pair.pubkey
        rkey3 == pair.pubkey
        rkey4 == pair.pubkey
      rkey1.clear()
      rkey2.clear()
  test "Generate/Sign/Serialize/Deserialize/Verify test":
    var message = "message to sign"
    for i in 0..<TestsCount:
      var kp = SecpKeyPair.random().expect("random key pair")
      var sig = kp.seckey.sign(message).expect("signature")
      var sersk = kp.seckey.getBytes()
      var serpk = kp.pubkey.getBytes()
      var sersig = sig.getBytes()
      discard SecpPrivateKey.init(sersk).expect("private key")
      var pubkey = SecpPublicKey.init(serpk).expect("public key")
      var csig = SecpSignature.init(sersig).expect("signature")
      check csig.verify(message, pubkey) == true
      var error = csig.getBytes()
      error[^1] = not error[^1]
      csig = SecpSignature.init(error).expect("signature")
      check csig.verify(message, pubkey) == false

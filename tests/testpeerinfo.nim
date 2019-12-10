
import unittest, options
import ../libp2p/crypto/crypto,
       ../libp2p/peerinfo,
       ../libp2p/peer

suite "PeerInfo":
  test "Should init with private key":
    let seckey = PrivateKey.random(RSA)
    var peerInfo = PeerInfo.init(seckey)
    var peerId = PeerID.init(seckey)

    check peerId == peerInfo.peerId
    check seckey == peerInfo.privateKey
    check seckey.getKey == peerInfo.publicKey.get()

  test "Should init with public key":
    let seckey = PrivateKey.random(RSA)
    var peerInfo = PeerInfo.init(seckey.getKey())
    var peerId = PeerID.init(seckey.getKey())

    check peerId == peerInfo.peerId
    check seckey.getKey == peerInfo.publicKey.get()

  test "Should init from PeerId with public key":
    let seckey = PrivateKey.random(Ed25519)
    var peerInfo = PeerInfo.init(PeerID.init(seckey.getKey()))
    var peerId = PeerID.init(seckey.getKey())

    check peerId == peerInfo.peerId
    check seckey.getKey == peerInfo.publicKey.get()

  test "Should init from CIDv0 string":
    var peerInfo = PeerInfo.init("QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N")

    check:
      PeerID.init("QmYyQSo1c1Ym7orWxLYvCrM2EmxFTANf8wXmmE7DWjhx5N") == peerInfo.peerId

  # TODO: CIDv1 is handling is missing from PeerID
  # https://github.com/status-im/nim-libp2p/issues/53
  # test "Should init from CIDv1 string":
  #   var peerInfo = PeerInfo.init("bafzbeie5745rpv2m6tjyuugywy4d5ewrqgqqhfnf445he3omzpjbx5xqxe")

  #   check:
  #     PeerID.init("bafzbeie5745rpv2m6tjyuugywy4d5ewrqgqqhfnf445he3omzpjbx5xqxe") == peerInfo.peerId

  test "Should return none if pubkey is missing from id":
    let peerInfo = PeerInfo.init(PeerID.init(PrivateKey.random(RSA)))
    check peerInfo.publicKey.isNone

  test "Should return some if pubkey is present in id":
    let peerInfo = PeerInfo.init(PeerID.init(PrivateKey.random(Ed25519)))
    check peerInfo.publicKey.isSome

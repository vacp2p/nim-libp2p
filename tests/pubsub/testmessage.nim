import unittest2

{.used.}

import options
import stew/byteutils
import ../../libp2p/[peerid, peerinfo,
                     crypto/crypto,
                     protocols/pubsub/errors,
                     protocols/pubsub/rpc/message,
                     protocols/pubsub/rpc/messages]

let rng = newRng()

suite "Message":
  test "signature":
    var seqno = 11'u64
    let
      peer = PeerInfo.new(PrivateKey.random(ECDSA, rng[]).get())
      msg = Message.init(some(peer), @[], "topic", some(seqno), sign = true)

    check verify(msg)

  test "defaultMsgIdProvider success":
    let
      seqno = 11'u64
      pkHex =
        """08011240B9EA7F0357B5C1247E4FCB5AD09C46818ECB07318CA84711875F4C6C
        E6B946186A4EB44E0D714B2A2D48263D75CF52D30BEF9D9AE2A9FEB7DAF1775F
        E731065A"""
      seckey = PrivateKey.init(fromHex(stripSpaces(pkHex)))
                .expect("valid private key bytes")
      peer = PeerInfo.new(seckey)
      msg = Message.init(some(peer), @[], "topic", some(seqno), sign = true)
      msgIdResult = msg.defaultMsgIdProvider()

    check:
      msgIdResult.isOk
      string.fromBytes(msgIdResult.get) ==
        "000000000000000b12D3KooWGyLzSt9g4U9TdHYDvVWAs5Ht4WrocgoyqPxxvnqAL8qw"

  test "defaultMsgIdProvider error - no source peer id":
    let
      seqno = 11'u64
      pkHex =
        """08011240B9EA7F0357B5C1247E4FCB5AD09C46818ECB07318CA84711875F4C6C
        E6B946186A4EB44E0D714B2A2D48263D75CF52D30BEF9D9AE2A9FEB7DAF1775F
        E731065A"""
      seckey = PrivateKey.init(fromHex(stripSpaces(pkHex)))
                .expect("valid private key bytes")
      peer = PeerInfo.new(seckey)

    var msg = Message.init(peer.some, @[], "topic", some(seqno), sign = true)
    msg.fromPeer = PeerId()
    let msgIdResult = msg.defaultMsgIdProvider()

    check:
      msgIdResult.isErr
      msgIdResult.error == ValidationResult.Reject

  test "defaultMsgIdProvider error - no source seqno":
    let
      pkHex =
        """08011240B9EA7F0357B5C1247E4FCB5AD09C46818ECB07318CA84711875F4C6C
        E6B946186A4EB44E0D714B2A2D48263D75CF52D30BEF9D9AE2A9FEB7DAF1775F
        E731065A"""
      seckey = PrivateKey.init(fromHex(stripSpaces(pkHex)))
                .expect("valid private key bytes")
      peer = PeerInfo.new(seckey)
      msg = Message.init(some(peer), @[], "topic", uint64.none, sign = true)
      msgIdResult = msg.defaultMsgIdProvider()

    check:
      msgIdResult.isErr
      msgIdResult.error == ValidationResult.Reject

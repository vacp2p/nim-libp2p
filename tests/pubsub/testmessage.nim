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

  test "byteSize for Message":
    var msg = Message(
      fromPeer: PeerId(data: @[]),  # Empty seq[byte]
      data: @[1'u8, 2, 3],  # 3 bytes
      seqno: @[1'u8],  # 1 byte
      signature: @[],  # Empty seq[byte]
      key: @[1'u8],  # 1 byte
      topicIds: @["abc", "defgh"]  # 3 + 5 = 8 bytes
    )

    check byteSize(msg) == 3 + 1 + 1 + 8  # Total: 13 bytes

  test "byteSize for RPCMsg":
    var msg = RPCMsg(
      subscriptions: @[
        SubOpts(topic: "abc", subscribe: true),
        SubOpts(topic: "def", subscribe: false)
      ],  # 3 + 3 + 2 * sizeof(bool) bytes
      messages: @[
        Message(fromPeer: PeerId(data: @[]), data: @[1'u8, 2, 3], seqno: @[1'u8], signature: @[], key: @[1'u8], topicIds: @["abc", "defgh"]),
        Message(fromPeer: PeerId(data: @[]), data: @[], seqno: @[], signature: @[], key: @[], topicIds: @["abc"])
      ],  # byteSize: 13 + 3 = 16 bytes
      control: some(ControlMessage(
        ihave: @[
          ControlIHave(topicId: "ghi", messageIds: @[@[1'u8, 2, 3]])
        ],  # 3 + 3 bytes
        iwant: @[
          ControlIWant(messageIds: @[@[1'u8, 2]])
        ],  # 2 bytes
        graft: @[
          ControlGraft(topicId: "jkl")
        ],  # 3 bytes
        prune: @[
          ControlPrune(topicId: "mno", peers: @[PeerInfoMsg(peerId: PeerId(data: @[]), signedPeerRecord: @[])], backoff: 1)
        ]  # 3 + sizeof(uint64) bytes
      )),
      ping: @[],  # Empty seq[byte]
      pong: @[]  # Empty seq[byte]
    )

    let boolSize = sizeof(bool)
    let uint64Size = sizeof(uint64)
    check byteSize(msg) == (3 + 3 + 2 * boolSize) + 16 + (3 + 3 + 2 + 3 + 3 + uint64Size)
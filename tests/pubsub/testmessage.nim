import unittest2

{.used.}

import options, strutils
import stew/byteutils
import
  ../../libp2p/[
    peerid,
    peerinfo,
    crypto/crypto as crypto,
    protocols/pubsub/errors,
    protocols/pubsub/rpc/message,
    protocols/pubsub/rpc/messages,
    protocols/pubsub/rpc/protobuf,
  ]
import ../utils/async_tests

let rng = newRng()

suite "Message":
  test "signature":
    var seqno = 11'u64
    let
      peer = PeerInfo.new(PrivateKey.random(ECDSA, rng[]).get())
      msg = Message.init(some(peer), @[], "topic", some(seqno), sign = true)

    check verify(msg)

  test "signature with missing key":
    let
      seqno = 11'u64
      seckey = PrivateKey.random(Ed25519, rng[]).get()
      pubkey = seckey.getPublicKey().get()
      peer = PeerInfo.new(seckey)
    check peer.peerId.hasPublicKey() == true
    var msg = Message.init(some(peer), @[], "topic", some(seqno), sign = true)
    msg.key = @[]
    # get the key from fromPeer field (inlined)
    check verify(msg)

  test "signature without inlined pubkey in peerId":
    let
      seqno = 11'u64
      peer = PeerInfo.new(PrivateKey.random(RSA, rng[]).get())
    var msg = Message.init(some(peer), @[], "topic", some(seqno), sign = true)
    msg.key = @[]
    # shouldn't work since there's no key field
    # and the key is not inlined in peerid (too large)
    check verify(msg) == false

  test "defaultMsgIdProvider success":
    let
      seqno = 11'u64
      pkHex =
        """08011240B9EA7F0357B5C1247E4FCB5AD09C46818ECB07318CA84711875F4C6C
        E6B946186A4EB44E0D714B2A2D48263D75CF52D30BEF9D9AE2A9FEB7DAF1775F
        E731065A"""
      seckey = PrivateKey.init(crypto.fromHex(stripSpaces(pkHex))).expect(
          "valid private key bytes"
        )
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
      seckey = PrivateKey.init(crypto.fromHex(stripSpaces(pkHex))).expect(
          "valid private key bytes"
        )
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
      seckey = PrivateKey.init(crypto.fromHex(stripSpaces(pkHex))).expect(
          "valid private key bytes"
        )
      peer = PeerInfo.new(seckey)
      msg = Message.init(some(peer), @[], "topic", uint64.none, sign = true)
      msgIdResult = msg.defaultMsgIdProvider()

    check:
      msgIdResult.isErr
      msgIdResult.error == ValidationResult.Reject

  test "byteSize for RPCMsg":
    var msg = Message(
      fromPeer: PeerId(data: @['a'.byte, 'b'.byte]), # 2 bytes
      data: @[1'u8, 2, 3], # 3 bytes
      seqno: @[4'u8, 5], # 2 bytes
      signature: @['c'.byte, 'd'.byte], # 2 bytes
      key: @[6'u8, 7], # 2 bytes
      topic: "abcde", # 5 bytes
    )

    var peerInfo = PeerInfoMsg(
      peerId: PeerId(data: @['e'.byte]), # 1 byte
      signedPeerRecord: @['f'.byte, 'g'.byte] # 2 bytes
      ,
    )

    var controlIHave = ControlIHave(
      topicID: "ijk", # 3 bytes
      messageIDs: @[@['l'.byte], @['m'.byte, 'n'.byte]] # 1 + 2 = 3 bytes
      ,
    )

    var controlIWant = ControlIWant(
      messageIDs: @[@['o'.byte, 'p'.byte], @['q'.byte]] # 2 + 1 = 3 bytes
    )

    var controlGraft = ControlGraft(
      topicID: "rst" # 3 bytes
    )

    var controlPrune = ControlPrune(
      topicID: "uvw", # 3 bytes
      peers: @[peerInfo, peerInfo], # (1 + 2) * 2 = 6 bytes
      backoff: 12345678, # 8 bytes for uint64
    )

    var control = ControlMessage(
      ihave: @[controlIHave, controlIHave], # (3 + 3) * 2 = 12 bytes
      iwant: @[controlIWant], # 3 bytes
      graft: @[controlGraft], # 3 bytes
      prune: @[controlPrune], # 3 + 6 + 8 = 17 bytes
      idontwant: @[controlIWant] # 3 bytes
      ,
    )

    var rpcMsg = RPCMsg(
      subscriptions:
        @[
          SubOpts(subscribe: true, topic: "a".repeat(12)),
          SubOpts(subscribe: false, topic: "b".repeat(14)),
        ], # 1 + 12 + 1 + 14 = 28 bytes
      messages: @[msg, msg], # 16 * 2 = 32 bytes
      ping: @[1'u8, 2], # 2 bytes
      pong: @[3'u8, 4], # 2 bytes
      control: some(control), # 12 + 3 + 3 + 17 + 3 = 38 bytes
    )

    check byteSize(rpcMsg) == 28 + 32 + 2 + 2 + 38 # Total: 102 bytes

  # check correctly parsed ihave/iwant/graft/prune/idontwant messages
  # check value before & after decoding equal using protoc cmd tool for reference
  asyncTest "ControlMessage RPCMsg encoding and decoding":
    let id: seq[byte] = @[123]
    let message = RPCMsg(
      control: some(
        ControlMessage(
          ihave: @[ControlIHave(topicID: "foobar", messageIDs: @[id])],
          iwant: @[ControlIWant(messageIDs: @[id])],
          graft: @[ControlGraft(topicID: "foobar")],
          prune: @[ControlPrune(topicID: "foobar", backoff: 10.uint64)],
          idontwant: @[ControlIWant(messageIDs: @[id])],
        )
      )
    )
    #data encoded using protoc cmd tool
    let expectedEncoded: seq[byte] =
      @[
        26, 45, 10, 11, 10, 6, 102, 111, 111, 98, 97, 114, 18, 1, 123, 18, 3, 10, 1,
        123, 26, 8, 10, 6, 102, 111, 111, 98, 97, 114, 34, 10, 10, 6, 102, 111, 111, 98,
        97, 114, 24, 10, 42, 3, 10, 1, 123,
      ]

    let actualEncoded = encodeRpcMsg(message, true)
    check:
      actualEncoded == expectedEncoded

    let actualDecoded = decodeRpcMsg(expectedEncoded).value
    check:
      actualDecoded == message

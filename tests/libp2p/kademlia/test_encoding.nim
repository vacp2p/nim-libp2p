# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.used.}

import nimcrypto, results
import
  ../../../libp2p/[
    multiaddress,
    peerid,
    protobuf/minprotobuf,
    protocols/kademlia,
    protocols/kademlia/protobuf,
  ]
import ../../tools/unittest

template checkEncodeDecode(obj: untyped) =
  check obj == decode(typeof(obj), obj.encode()).get()

suite "KadDHT Protobuffers":
  const invalidType = uint32(999)

  test "encode/decode":
    let maddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()]
    checkEncodeDecode(
      Record(
        key: @[1'u8, 2, 3],
        value: Opt.some(@[4'u8, 5, 6]),
        timeReceived: Opt.some("2025-05-12T12:00:00Z"),
      )
    )
    # encode with hideConnectionStatus=false to preserve connection type for round-trip check
    let peer =
      Peer(id: @[1'u8, 2, 3], addrs: maddrs, connection: ConnectionStatus.connected)
    check peer == Peer.decode(peer.encode(hideConnectionStatus = false)).get()

    let msg = Message(
      msgType: MessageType.putValue,
      key: @[1'u8],
      record: Opt.some(
        Record(key: @[1'u8], value: Opt.some(@[2'u8]), timeReceived: Opt.some("t"))
      ),
      closerPeers: @[Peer(id: @[9'u8], addrs: maddrs, connection: canConnect)],
      providerPeers: @[Peer(id: @[9'u8], addrs: maddrs, connection: canConnect)],
    )
    check msg == Message.decode(msg.encode(hideConnectionStatus = false)).get()

  test "decode record with missing fields":
    var pb = initProtoBuffer()
    # no fields written
    check Record.decode(pb).isErr()

  test "decode peer with missing id (invalid)":
    var pb = initProtoBuffer()
    check:
      Peer.decode(pb).isErr()

  test "decode peer with invalid connection type":
    var pb = initProtoBuffer()
    pb.write(1, @[1'u8, 2, 3]) # id field
    pb.write(3, invalidType) # bogus connection type
    check:
      Peer.decode(pb).isErr()

  test "decode message with invalid msgType":
    var pb = initProtoBuffer()
    pb.write(1, invalidType) # invalid MessageType
    check:
      Message.decode(pb).isErr()

  test "decode message with invalid peer in closerPeers":
    let badPeerBuf = @[0'u8, 1, 2] # junk
    var pb = initProtoBuffer()
    pb.write(8, badPeerBuf) # closerPeers field
    check:
      Message.decode(pb).isErr()

  test "decode message with invalid embedded record":
    # encode junk data into field 3 (record)
    var pb = initProtoBuffer()
    pb.write(1, uint32(MessageType.putValue)) # valid msgType
    pb.write(3, @[0x00'u8, 0xFF, 0xAB]) # broken protobuf for record
    check:
      Message.decode(pb).isErr()

  test "peer with empty addr list and no connection":
    let peer =
      Peer(id: @[0x42'u8], addrs: @[], connection: ConnectionStatus.notConnected)
    let encoded = peer.encode()
    let decoded = Peer.decode(initProtoBuffer(encoded.buffer)).get()
    check:
      decoded == peer

  test "peer with multiple multiaddresses":
    let maddrs = @[
      MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get(),
      MultiAddress.init("/ip4/192.168.1.1/tcp/4001").get(),
      MultiAddress.init("/ip6/::1/tcp/9000").get(),
      MultiAddress.init("/dns4/example.com/tcp/443").get(),
    ]
    let peer = Peer(id: @[1'u8, 2, 3, 4, 5], addrs: maddrs, connection: canConnect)
    let encoded = peer.encode(hideConnectionStatus = false)
    let decoded = Peer.decode(initProtoBuffer(encoded.buffer)).get()
    check:
      decoded == peer
      decoded.addrs == maddrs

  test "message with empty closer/provider peers":
    let msg = Message(
      msgType: MessageType.ping,
      key: @[7'u8],
      record: Opt.none(Record),
      closerPeers: @[],
      providerPeers: @[],
    )
    let encoded = msg.encode()
    let decoded = Message.decode(encoded).tryGet()
    check:
      decoded == msg

  test "peer with addr but missing id":
    var pb = initProtoBuffer()
    let maddr = MultiAddress.init("/ip4/1.2.3.4/tcp/1234").tryGet()
    pb.write(2, maddr.data.buffer)
    check:
      Peer.decode(pb).isErr()

  test "encode peer with hideConnectionStatus=true always emits notConnected":
    let maddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()]
    for ct in [connected, canConnect, cannotConnect, notConnected]:
      let peer = Peer(id: @[1'u8, 2, 3], addrs: maddrs, connection: ct)
      let decoded = Peer
        .decode(initProtoBuffer(peer.encode(hideConnectionStatus = true).buffer))
        .get()
      check decoded.connection == ConnectionStatus.notConnected

  test "encode peer with hideConnectionStatus=false preserves actual connection type":
    let maddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()]
    for ct in [connected, canConnect, cannotConnect, notConnected]:
      let peer = Peer(id: @[1'u8, 2, 3], addrs: maddrs, connection: ct)
      let decoded = Peer
        .decode(initProtoBuffer(peer.encode(hideConnectionStatus = false).buffer))
        .get()
      check decoded.connection == ct

  test "decode all four ConnectionStatus values":
    let maddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()]
    for ct in [notConnected, connected, canConnect, cannotConnect]:
      var pb = initProtoBuffer()
      pb.write(1, @[1'u8, 2, 3])
      pb.write(2, maddrs[0].data.buffer)
      pb.write(3, uint32(ord(ct)))
      pb.finish()
      let p = Peer.decode(pb).get()
      check p.connection == ct

  test "encode message with hideConnectionStatus=true hides connection in both peer lists":
    let maddrs = @[MultiAddress.init("/ip4/127.0.0.1/tcp/9000").get()]
    let msg = Message(
      msgType: MessageType.findNode,
      key: @[1'u8],
      closerPeers: @[Peer(id: @[2'u8], addrs: maddrs, connection: connected)],
      providerPeers: @[Peer(id: @[3'u8], addrs: maddrs, connection: canConnect)],
    )
    let decoded = Message.decode(msg.encode(hideConnectionStatus = true)).get()
    check decoded.closerPeers[0].connection == ConnectionStatus.notConnected
    check decoded.providerPeers[0].connection == ConnectionStatus.notConnected

  test "KadDHTConfig hideConnectionStatus defaults to true":
    let cfg = KadDHTConfig.new()
    check cfg.hideConnectionStatus == true

when defined(kadProviderRejection):
  suite "KadDHT Protobuffers - kadProviderRejection":
    test "round-trip for AddProviderStatus":
      let accepted = Message(
        msgType: MessageType.addProvider,
        providerStatus: Opt.some(AddProviderStatus.accepted),
      )
      let rejected = Message(
        msgType: MessageType.addProvider,
        providerStatus: Opt.some(AddProviderStatus.rejected),
      )
      let noStatus = Message(
        msgType: MessageType.addProvider, providerStatus: Opt.none(AddProviderStatus)
      )

      let decodedAccepted = Message.decode(accepted.encode().buffer).valueOr:
        raiseAssert("decode of accepted failed")
      let decodedRejected = Message.decode(rejected.encode().buffer).valueOr:
        raiseAssert("decode of rejected failed")
      let decodedNoStatus = Message.decode(noStatus.encode().buffer).valueOr:
        raiseAssert("decode of noStatus failed")

      check:
        decodedAccepted.providerStatus == Opt.some(AddProviderStatus.accepted)
        decodedRejected.providerStatus == Opt.some(AddProviderStatus.rejected)
        decodedNoStatus.providerStatus.isNone()

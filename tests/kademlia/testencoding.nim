{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import ../tools/unittests
import ../../libp2p/protobuf/minprotobuf
import ../../libp2p/protocols/kademlia/protobuf
import ../../libp2p/multiaddress
import results

template checkEncodeDecode(obj: untyped) =
  check obj == decode(typeof(obj), obj.encode()).get()

suite "kademlia protobuffers":
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
    checkEncodeDecode(
      Peer(id: @[1'u8, 2, 3], addrs: maddrs, connection: ConnectionType.connected)
    )

    checkEncodeDecode(
      Message(
        msgType: MessageType.findNode,
        key: @[1'u8],
        record: Opt.some(
          Record(key: @[1'u8], value: Opt.some(@[2'u8]), timeReceived: Opt.some("t"))
        ),
        closerPeers: @[Peer(id: @[9'u8], addrs: maddrs, connection: canConnect)],
        providerPeers: @[Peer(id: @[9'u8], addrs: maddrs, connection: canConnect)],
      )
    )

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
    let peer = Peer(id: @[0x42'u8], addrs: @[], connection: ConnectionType.notConnected)
    let encoded = peer.encode()
    let decoded = Peer.decode(initProtoBuffer(encoded.buffer)).get()
    check:
      decoded == peer

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

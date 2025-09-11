{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import unittest2
import ../../libp2p/protobuf/minprotobuf
import ../../libp2p/protocols/kademlia/protobuf
import ../../libp2p/multiaddress
import options
import results

suite "kademlia protobuffers":
  const invalidType = uint32(999)

  proc valFromResultOption[T](res: ProtoResult[Option[T]]): T =
    assert res.isOk()
    assert res.value().isSome()
    return res.value().unsafeGet()

  test "record encode/decode":
    let rec = Record(
      key: some(@[1'u8, 2, 3]),
      value: some(@[4'u8, 5, 6]),
      timeReceived: some("2025-05-12T12:00:00Z"),
    )
    let encoded = rec.encode()
    let decoded = Record.decode(encoded).valFromResultOption
    check:
      decoded.key.get() == rec.key.get()
      decoded.value.get() == rec.value.get()
      decoded.timeReceived.get() == rec.timeReceived.get()

  test "peer encode/decode":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").tryGet()
    let peer =
      Peer(id: @[1'u8, 2, 3], addrs: @[maddr], connection: ConnectionType.connected)
    let encoded = peer.encode()
    var decoded = Peer.decode(initProtoBuffer(encoded.buffer)).valFromResultOption
    check:
      decoded == peer

  test "message encode/decode roundtrip":
    let maddr = MultiAddress.init("/ip4/10.0.0.1/tcp/4001").tryGet()
    let peer = Peer(id: @[9'u8], addrs: @[maddr], connection: canConnect)
    let r = Record(key: some(@[1'u8]), value: some(@[2'u8]), timeReceived: some("t"))
    let msg = Message(
      msgType: MessageType.findNode,
      key: some(@[7'u8]),
      record: some(r),
      closerPeers: @[peer],
      providerPeers: @[peer],
    )
    let encoded = msg.encode()
    let decoded = Message.decode(encoded.buffer).tryGet()
    check:
      decoded == msg

  test "decode record with missing fields":
    var pb = initProtoBuffer()
    # no fields written
    let rec = Record.decode(pb).valFromResultOption
    check:
      rec.key.isNone()
      rec.value.isNone()
      rec.timeReceived.isNone()

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
      Message.decode(pb.buffer).isErr()

  test "decode message with invalid peer in closerPeers":
    let badPeerBuf = @[0'u8, 1, 2] # junk
    var pb = initProtoBuffer()
    pb.write(8, badPeerBuf) # closerPeers field
    check:
      Message.decode(pb.buffer).isErr()

  test "decode message with invalid embedded record":
    # encode junk data into field 3 (record)
    var pb = initProtoBuffer()
    pb.write(1, uint32(MessageType.putValue)) # valid msgType
    pb.write(3, @[0x00'u8, 0xFF, 0xAB]) # broken protobuf for record
    check:
      Message.decode(pb.buffer).isErr()

  test "decode message with empty embedded record":
    var recordPb = initProtoBuffer() # no fields
    var pb = initProtoBuffer()
    pb.write(1, uint32(MessageType.getValue))
    pb.write(3, recordPb.buffer)
    let decoded = Message.decode(pb.buffer).tryGet()
    check:
      decoded.record.isSome()
      decoded.record.get().key.isNone()

  test "peer with empty addr list and no connection":
    let peer = Peer(id: @[0x42'u8], addrs: @[], connection: ConnectionType.notConnected)
    let encoded = peer.encode()
    let decoded = Peer.decode(initProtoBuffer(encoded.buffer)).valFromResultOption
    check:
      decoded == peer

  test "message with empty closer/provider peers":
    let msg = Message(
      msgType: MessageType.ping,
      key: none[seq[byte]](),
      record: none[Record](),
      closerPeers: @[],
      providerPeers: @[],
    )
    let encoded = msg.encode()
    let decoded = Message.decode(encoded.buffer).tryGet()
    check:
      decoded == msg

  test "peer with addr but missing id":
    var pb = initProtoBuffer()
    let maddr = MultiAddress.init("/ip4/1.2.3.4/tcp/1234").tryGet()
    pb.write(2, maddr.data.buffer)
    check:
      Peer.decode(pb).isErr()

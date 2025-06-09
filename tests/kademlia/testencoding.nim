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
import results

suite "kademlia protobuffers":
  test "record encode/decode":
    let rec = Record(
      key: Opt.some(@[1'u8, 2, 3]),
      value: Opt.some(@[4'u8, 5, 6]),
      timeReceived: Opt.some("2025-05-12T12:00:00Z"),
    )
    let encoded = rec.encode()
    let decoded = Record.decode(encoded).get()
    check:
      decoded.key.get() == rec.key.get()
      decoded.value.get() == rec.value.get()
      decoded.timeReceived.get() == rec.timeReceived.get()

  test "peer encode/decode":
    let maddr = MultiAddress.init("/ip4/127.0.0.1/tcp/9000").tryGet()
    let peer = Peer(id: @[1'u8, 2, 3], addrs: @[maddr], connection: connected)
    let encoded = peer.encode()
    let decodedRes = Peer.decode(initProtoBuffer(encoded.buffer))
    check decodedRes.isSome()
    let decoded = decodedRes.get()
    check:
      decoded.id == peer.id
      decoded.addrs.len == 1
      decoded.addrs[0].data == maddr.data
      decoded.connection == connected

  test "message encode/decode roundtrip":
    let maddr = MultiAddress.init("/ip4/10.0.0.1/tcp/4001").tryGet()
    let peer = Peer(id: @[9'u8], addrs: @[maddr], connection: canConnect)
    let msg = Message(
      msgType: Opt.some(findNode),
      key: Opt.some(@[7'u8]),
      record: Opt.some(
        Record(
          key: Opt.some(@[1'u8]), value: Opt.some(@[2'u8]), timeReceived: Opt.some("t")
        )
      ),
      closerPeers: @[peer],
      providerPeers: @[peer],
    )
    let encoded = msg.encode()
    let decodedRes = Message.decode(encoded.buffer)
    check decodedRes.isSome()
    let decoded = decodedRes.get()
    check:
      decoded.msgType.get() == findNode
      decoded.key.get() == @[7'u8]
      decoded.record.get().key.get() == @[1'u8]
      decoded.closerPeers.len == 1
      decoded.providerPeers.len == 1

  test "decode record with missing fields":
    var pb = initProtoBuffer()
    # no fields written
    let res = Record.decode(pb)
    check res.isSome()
    let rec = res.get()
    check rec.key.isNone()
    check rec.value.isNone()
    check rec.timeReceived.isNone()

  test "decode peer with missing id (invalid)":
    var pb = initProtoBuffer()
    let res = Peer.decode(pb)
    check res.isNone()

  test "decode peer with invalid connection type":
    var pb = initProtoBuffer()
    pb.write(1, @[1'u8, 2, 3]) # id field
    pb.write(3, uint32(999)) # bogus connection type
    let res = Peer.decode(pb)
    check res.isNone()

  test "decode message with invalid msgType":
    var pb = initProtoBuffer()
    pb.write(1, uint32(999)) # invalid MessageType
    let res = Message.decode(pb.buffer)
    check res.isNone()

  test "decode message with invalid peer in closerPeers":
    let badPeerBuf = @[0'u8, 1, 2] # junk
    var pb = initProtoBuffer()
    pb.write(8, badPeerBuf) # closerPeers field
    let res = Message.decode(pb.buffer)
    check res.isNone()

  test "decode message with invalid embedded record":
    # encode junk data into field 3 (record)
    var pb = initProtoBuffer()
    pb.write(1, uint32(putValue)) # valid msgType
    pb.write(3, @[0x00'u8, 0xFF, 0xAB]) # broken protobuf for record
    let res = Message.decode(pb.buffer)
    check res.isSome()
    check res.unsafeGet().record.isNone()

  test "decode message with empty embedded record":
    var recordPb = initProtoBuffer() # no fields
    var pb = initProtoBuffer()
    pb.write(1, uint32(getValue))
    pb.write(3, recordPb.buffer)
    let res = Message.decode(pb.buffer)
    check res.isSome()
    let msg = res.get()
    check msg.record.isSome()
    check msg.record.get().key.isNone()

  test "peer with empty addr list and no connection":
    let peer = Peer(id: @[0x42'u8], addrs: @[], connection: ConnectionType.notConnected)
    let encoded = peer.encode()
    let decodedRes = Peer.decode(initProtoBuffer(encoded.buffer))
    check:
      decodedRes.isSome()
      decodedRes.get().id == @[0x42'u8]
      decodedRes.get().addrs.len == 0
      decodedRes.get().connection == ConnectionType.notConnected

  test "message with empty closer/provider peers":
    let msg = Message(
      msgType: Opt.some(ping),
      key: Opt.none(seq[byte]),
      record: Opt.none(Record),
      closerPeers: @[],
      providerPeers: @[],
    )
    let encoded = msg.encode()
    let decodedRes = Message.decode(encoded.buffer)
    check decodedRes.isSome()
    let decoded = decodedRes.get()
    check:
      decoded.msgType.get() == ping
      decoded.closerPeers.len == 0
      decoded.providerPeers.len == 0

  test "peer with addr but missing id":
    var pb = initProtoBuffer()
    let maddr = MultiAddress.init("/ip4/1.2.3.4/tcp/1234").tryGet()
    pb.write(2, maddr.data.buffer)
    let res = Peer.decode(pb)
    check res.isNone()

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/sets
import chronos, results
import ../../../libp2p/[peerid, protocols/kademlia, crypto/crypto]
import ../../tools/[unittest, crypto]

let NoOp = Opt.some(noOpHasher)

proc makeKeyInBucket(bucket: int, tag: byte): Key =
  ## Key landing in `bucket` of an all-zero selfId table. `tag` keeps keys apart.
  var buf: array[IdLength, byte]
  buf[bucket div 8] = 0x80'u8 shr (bucket mod 8)
  buf[IdLength - 1] = tag
  @buf

proc makeEmptyTable(replication: int): RoutingTable =
  RoutingTable.new(
    Key.init([0'u8]),
    RoutingTableConfig.new(
      replication = replication, hasher = NoOp, selfIdPreHashed = true
    ),
  )

proc fillBucket(rtable: RoutingTable, bucket: int, count: int) =
  for i in 0 ..< count:
    doAssert rtable.insert(makeKeyInBucket(bucket, i.byte))

suite "KadDHT Keyspace Regions":
  test "region prefix keeps the leading bits and clears the rest":
    let key = Key.init([0b1011_0110'u8, 0b1111_0000])
    check:
      key.regionPrefix(0, NoOp) == newSeq[byte](0)
      key.regionPrefix(1, NoOp) == @[0b1000_0000'u8]
      key.regionPrefix(4, NoOp) == @[0b1011_0000'u8]
      key.regionPrefix(8, NoOp) == @[0b1011_0110'u8]
      key.regionPrefix(12, NoOp) == @[0b1011_0110'u8, 0b1111_0000]

  test "region prefix is clamped to the hash length":
    check Key.init([0xFF'u8]).regionPrefix(MaxRegionBits + 8, NoOp).len == IdLength

  test "keys share a region exactly when their leading bits match":
    let
      a = Key.init([0b1010_0000'u8])
      b = Key.init([0b1011_0000'u8])
    check:
      a.regionPrefix(3, NoOp) == b.regionPrefix(3, NoOp)
      a.regionPrefix(4, NoOp) != b.regionPrefix(4, NoOp)

  test "zero bits groups every key into one region":
    let keys = @[Key.init([0x00'u8]), Key.init([0x80'u8]), Key.init([0xFF'u8])]
    check keys.keyspaceRegions(0, NoOp) == @[keys]

  test "regions partition the keys by prefix":
    let
      zeroPrefix = @[Key.init([0x00'u8]), Key.init([0x01'u8])]
      onePrefix = @[Key.init([0x80'u8]), Key.init([0xC0'u8]), Key.init([0xFF'u8])]
    check (zeroPrefix & onePrefix).keyspaceRegions(1, NoOp) == @[zeroPrefix, onePrefix]

  test "an empty key set yields no regions":
    check newSeq[Key]().keyspaceRegions(4, NoOp).len == 0

  test "region bits are unknown while no bucket is full":
    let rtable = makeEmptyTable(4)
    check rtable.regionBits().isNone()

    rtable.fillBucket(2, 3)
    check rtable.regionBits().isNone()

  test "region bits follow the deepest full bucket":
    let rtable = makeEmptyTable(4)

    rtable.fillBucket(2, 4)
    check rtable.regionBits() == Opt.some(3)

    rtable.fillBucket(5, 4)
    check rtable.regionBits() == Opt.some(6)

    # A deeper bucket that is not full carries no evidence of network size.
    rtable.fillBucket(7, 3)
    check rtable.regionBits() == Opt.some(6)

  test "closestFirst orders peers by distance to the key":
    let hasher = Opt.none(XorDHasher)
    let key = PeerId.random(rng()).get().toKey()
    let peers = PeerId.random(8, rng()).get()

    let ordered = peers.closestFirst(key, hasher)
    check:
      ordered.len == peers.len
      ordered.toHashSet() == peers.toHashSet()

    for i in 1 ..< ordered.len:
      check xorDistance(ordered[i - 1], key, hasher) <=
        xorDistance(ordered[i], key, hasher)

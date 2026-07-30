# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/[algorithm, sequtils, sets]
import chronos, results
import ../../../libp2p/[peerid, protocols/kademlia, crypto/crypto]
import ../../tools/[unittest, crypto]

let NoOp = Opt.some(noOpHasher)

proc keyFrom(bytes: openArray[byte]): Key =
  ## Key whose `noOpHasher` hash starts with `bytes`.
  var buf: array[IdLength, byte]
  for i, b in bytes:
    buf[i] = b
  @buf

proc keyInBucket(bucket: int, tag: byte): Key =
  ## Key landing in `bucket` of an all-zero selfId table. `tag` keeps keys apart.
  var buf: array[IdLength, byte]
  buf[bucket div 8] = 0x80'u8 shr (bucket mod 8)
  buf[IdLength - 1] = tag
  @buf

proc emptyTable(replication: int): RoutingTable =
  RoutingTable.new(
    keyFrom([0'u8]),
    RoutingTableConfig.new(
      replication = replication, hasher = NoOp, selfIdPreHashed = true
    ),
  )

proc fillBucket(rtable: RoutingTable, bucket: int, count: int) =
  for i in 0 ..< count:
    doAssert rtable.insert(keyInBucket(bucket, i.byte))

suite "KadDHT Keyspace Regions":
  test "region prefix keeps the leading bits and clears the rest":
    let key = keyFrom([0b1011_0110'u8, 0b1111_0000])
    check:
      key.regionPrefix(0, NoOp) == newSeq[byte](0)
      key.regionPrefix(1, NoOp) == @[0b1000_0000'u8]
      key.regionPrefix(4, NoOp) == @[0b1011_0000'u8]
      key.regionPrefix(8, NoOp) == @[0b1011_0110'u8]
      key.regionPrefix(12, NoOp) == @[0b1011_0110'u8, 0b1111_0000]

  test "region prefix is clamped to the hash length":
    check keyFrom([0xFF'u8]).regionPrefix(MaxRegionBits + 8, NoOp).len == IdLength

  test "keys share a region exactly when their leading bits match":
    let
      a = keyFrom([0b1010_0000'u8])
      b = keyFrom([0b1011_0000'u8])
    check:
      a.regionPrefix(3, NoOp) == b.regionPrefix(3, NoOp)
      a.regionPrefix(4, NoOp) != b.regionPrefix(4, NoOp)

  test "zero bits groups every key into one region":
    let keys = @[keyFrom([0x00'u8]), keyFrom([0x80'u8]), keyFrom([0xFF'u8])]
    let regions = keys.keyspaceRegions(0, NoOp)
    check:
      regions.len == 1
      regions[0].toHashSet() == keys.toHashSet()

  test "regions partition the keys by prefix":
    let keys = @[
      keyFrom([0x00'u8]),
      keyFrom([0x01'u8]),
      keyFrom([0x80'u8]),
      keyFrom([0xC0'u8]),
      keyFrom([0xFF'u8]),
    ]
    let regions = keys.keyspaceRegions(1, NoOp)

    check:
      regions.len == 2
      regions.mapIt(it.len).sorted() == @[2, 3]
      regions.concat().toHashSet() == keys.toHashSet()

    for region in regions:
      check region.allIt(it.regionPrefix(1, NoOp) == region[0].regionPrefix(1, NoOp))

  test "an empty key set yields no regions":
    check newSeq[Key]().keyspaceRegions(4, NoOp).len == 0

  test "region bits are unknown while no bucket is full":
    let rtable = emptyTable(4)
    check rtable.regionBits().isNone()

    rtable.fillBucket(2, 3)
    check rtable.regionBits().isNone()

  test "region bits follow the deepest full bucket":
    let rtable = emptyTable(4)

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
    let peers = PeerId.random(8, rng())

    let ordered = peers.closestFirst(key, hasher)
    check:
      ordered.len == peers.len
      ordered.toHashSet() == peers.toHashSet()

    for i in 1 ..< ordered.len:
      check xorDistance(ordered[i - 1], key, hasher) <=
        xorDistance(ordered[i], key, hasher)

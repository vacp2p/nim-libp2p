# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, chronicles, results
import ../../../libp2p/[protocols/kademlia, crypto/crypto]
import ../../tools/[unittest, crypto]

proc testKey*(x: byte): Key =
  var buf: array[IdLength, byte]
  buf[31] = x
  return @buf

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

suite "KadDHT Routing Table":
  const TargetBucket = 6

  test "inserts single key in correct bucket":
    let selfId = testKey(0)
    var rt = RoutingTable.new(selfId)
    let other = testKey(0b10000000)
    discard rt.insert(other)

    let idx = bucketIndex(selfId, other, Opt.none(XorDHasher))
    check:
      rt.buckets.len > idx
      rt.buckets[idx].peers.len == 1
      rt.buckets[idx].peers[0].nodeId == other

  test "does not insert beyond capacity":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    for _ in 0 ..< config.replication + 5:
      let kid = randomKeyInBucket(selfId, TargetBucket, rng)
      discard rt.insert(kid)

    check TargetBucket < rt.buckets.len
    let bucket = rt.buckets[TargetBucket]
    check bucket.peers.len <= config.replication

  test "evicts oldest key at max capacity":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    for _ in 0 ..< config.replication + 10:
      let kid = randomKeyInBucket(selfId, TargetBucket, rng)
      discard rt.insert(kid)

    check rt.buckets[TargetBucket].peers.len == config.replication

    # new entry should evict oldest entry
    let (oldest, oldestIdx) = rt.buckets[TargetBucket].oldestPeer()

    check rt.insert(randomKeyInBucket(selfId, TargetBucket, rng))

    let (oldestAfterInsert, _) = rt.buckets[TargetBucket].oldestPeer()

    # oldest was evicted
    check oldest.nodeId != oldestAfterInsert.nodeId

  test "findClosest returns sorted keys":
    let selfId = testKey(0)
    var rt = RoutingTable.new(
      selfId, config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    )
    let ids = @[testKey(1), testKey(2), testKey(3), testKey(4), testKey(5)]
    for id in ids:
      discard rt.insert(id)

    let res = rt.findClosest(testKey(1), 3)

    check:
      res.len == 3
      res == @[testKey(1), testKey(3), testKey(2)]

  test "isStale returns true for empty or old keys":
    var bucket: Bucket
    check isStale(bucket) == true

    bucket.peers = @[NodeEntry(nodeId: testKey(1), lastSeen: Moment.now() - 40.minutes)]
    check isStale(bucket) == true

    bucket.peers = @[NodeEntry(nodeId: testKey(1), lastSeen: Moment.now())]
    check isStale(bucket) == false

  test "randomKeyInBucket returns id at correct distance":
    let selfId = testKey(0)
    var rid = randomKeyInBucket(selfId, TargetBucket, rng)
    let idx = bucketIndex(selfId, rid, Opt.some(noOpHasher))
    check:
      idx == TargetBucket
      rid != selfId

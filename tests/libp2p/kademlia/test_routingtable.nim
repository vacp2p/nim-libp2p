# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, results
import ../../../libp2p/[protocols/kademlia, crypto/crypto]
import ../../tools/[unittest, crypto]

proc testKey*(x: byte): Key =
  var buf: array[IdLength, byte]
  buf[31] = x
  return @buf

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

  test "does not insert self":
    let selfId = testKey(0)
    var rt = RoutingTable.new(selfId)

    check not rt.insert(selfId)

  test "does not insert beyond capacity":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    for _ in 0 ..< config.replication + 5:
      let kid = randomKeyInBucket(selfId, TargetBucket, rng[])
      discard rt.insert(kid)

    check TargetBucket < rt.buckets.len
    let bucket = rt.buckets[TargetBucket]
    check bucket.peers.len <= config.replication

  test "evicts oldest key at max capacity":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    for _ in 0 ..< config.replication + 10:
      let kid = randomKeyInBucket(selfId, TargetBucket, rng[])
      discard rt.insert(kid)

    check rt.buckets[TargetBucket].peers.len == config.replication

    # new entry should evict oldest entry
    let (oldest, oldestIdx) = rt.buckets[TargetBucket].oldestPeer()

    check rt.insert(randomKeyInBucket(selfId, TargetBucket, rng[]))

    let (oldestAfterInsert, _) = rt.buckets[TargetBucket].oldestPeer()

    # oldest was evicted
    check oldest.nodeId != oldestAfterInsert.nodeId

  test "re-insert existing key updates lastSeen":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)

    let key1 = randomKeyInBucket(selfId, TargetBucket, rng[])
    let key2 = randomKeyInBucket(selfId, TargetBucket, rng[])
    let key3 = randomKeyInBucket(selfId, TargetBucket, rng[])

    discard rt.insert(key1)
    discard rt.insert(key2)
    discard rt.insert(key3)

    check rt.buckets[TargetBucket].peers[0].nodeId == key1

    let previousLastSeen = rt.buckets[TargetBucket].peers[0].lastSeen

    discard rt.insert(key1)

    # Re-inserting existing key updates lastSeen timestamp without changing bucket position
    check:
      rt.buckets[TargetBucket].peers[0].nodeId == key1
      rt.buckets[TargetBucket].peers[0].lastSeen > previousLastSeen

  test "findClosest returns sorted keys":
    let selfId = testKey(0)
    var rt = RoutingTable.new(
      selfId, config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    )
    let ids = @[testKey(1), testKey(2), testKey(3), testKey(4), testKey(5)]
    for id in ids:
      discard rt.insert(id)

    const peerCount = 3
    let res = rt.findClosest(testKey(1), peerCount)

    check:
      res.len == peerCount
      res == @[testKey(1), testKey(3), testKey(2)]

  test "findClosest returns all keys if less than n available":
    let selfId = testKey(0)
    var rt = RoutingTable.new(
      selfId, config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    )
    let ids = @[testKey(1), testKey(2), testKey(3)]
    for id in ids:
      discard rt.insert(id)

    let res = rt.findClosest(testKey(1), 5) # n > ids.len

    check:
      res.len == ids.len
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
    var rid = randomKeyInBucket(selfId, TargetBucket, rng[])
    let idx = bucketIndex(selfId, rid, Opt.some(noOpHasher))
    check:
      idx == TargetBucket
      rid != selfId

  test "purgeExpired is no-op when purgeStaleEntries is false":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)

    let kid = randomKeyInBucket(selfId, TargetBucket, rng[])
    discard rt.insert(kid)
    rt.buckets[TargetBucket].peers[0].lastSeen =
      Moment.now() - DefaultBucketStaleTime - 1.seconds

    rt.purgeExpired()

    check rt.buckets[TargetBucket].peers.len == 1

  test "purgeExpired removes stale entries when purgeStaleEntries is true":
    let selfId = testKey(0)
    let config =
      RoutingTableConfig.new(hasher = Opt.some(noOpHasher), purgeStaleEntries = true)
    var rt = RoutingTable.new(selfId, config)

    let kid = randomKeyInBucket(selfId, TargetBucket, rng[])
    discard rt.insert(kid)
    rt.buckets[TargetBucket].peers[0].lastSeen =
      Moment.now() - DefaultBucketStaleTime - 1.seconds

    rt.purgeExpired()

    check rt.buckets[TargetBucket].peers.len == 0

  test "purgeExpired keeps fresh entries":
    let selfId = testKey(0)
    let config =
      RoutingTableConfig.new(hasher = Opt.some(noOpHasher), purgeStaleEntries = true)
    var rt = RoutingTable.new(selfId, config)

    let stale = randomKeyInBucket(selfId, TargetBucket, rng[])
    let fresh = randomKeyInBucket(selfId, TargetBucket, rng[])
    discard rt.insert(stale)
    discard rt.insert(fresh)

    rt.buckets[TargetBucket].peers[0].lastSeen =
      Moment.now() - DefaultBucketStaleTime - 1.seconds

    rt.purgeExpired()

    check:
      rt.buckets[TargetBucket].peers.len == 1
      rt.buckets[TargetBucket].peers[0].nodeId == fresh

  test "purgeExpired removes stale entries across multiple buckets":
    let selfId = testKey(0)
    let config =
      RoutingTableConfig.new(hasher = Opt.some(noOpHasher), purgeStaleEntries = true)
    var rt = RoutingTable.new(selfId, config)

    let kid1 = randomKeyInBucket(selfId, TargetBucket, rng[])
    let kid2 = randomKeyInBucket(selfId, TargetBucket + 1, rng[])
    discard rt.insert(kid1)
    discard rt.insert(kid2)

    rt.buckets[TargetBucket].peers[0].lastSeen =
      Moment.now() - DefaultBucketStaleTime - 1.seconds
    rt.buckets[TargetBucket + 1].peers[0].lastSeen =
      Moment.now() - DefaultBucketStaleTime - 1.seconds

    rt.purgeExpired()

    check:
      rt.buckets[TargetBucket].peers.len == 0
      rt.buckets[TargetBucket + 1].peers.len == 0

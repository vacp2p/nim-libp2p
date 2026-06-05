# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, results, algorithm
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

    let idx = rt.bucketIndex(other)
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
      let kid = randomKeyInBucket(selfId, TargetBucket, rng())
      discard rt.insert(kid)

    check TargetBucket < rt.buckets.len
    let bucket = rt.buckets[TargetBucket]
    check bucket.peers.len <= config.replication

  test "evicts oldest key at max capacity":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    for _ in 0 ..< config.replication + 10:
      let kid = randomKeyInBucket(selfId, TargetBucket, rng())
      discard rt.insert(kid)

    check rt.buckets[TargetBucket].peers.len == config.replication

    # new entry should evict oldest entry
    let (oldest, _) = rt.buckets[TargetBucket].oldestPeer()

    check rt.insert(randomKeyInBucket(selfId, TargetBucket, rng()))

    let (oldestAfterInsert, _) = rt.buckets[TargetBucket].oldestPeer()

    # oldest was evicted
    check oldest.nodeId != oldestAfterInsert.nodeId

  test "re-insert existing key updates lastSeen":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)

    let key1 = randomKeyInBucket(selfId, TargetBucket, rng())
    let key2 = randomKeyInBucket(selfId, TargetBucket, rng())
    let key3 = randomKeyInBucket(selfId, TargetBucket, rng())

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

  test "findClosest respects selfIdPreHashed=true (avoids double-hashing target)":
    # Service discovery tables use pre-hashed serviceId as self + targets.
    # findClosest must compute dist(target_raw, H(peer)) not H(target) to match bucketIndex.
    let selfId = testKey(0)
    let config =
      RoutingTableConfig.new(hasher = Opt.none(XorDHasher), selfIdPreHashed = true)
    var rt = RoutingTable.new(selfId, config)
    let p1 = testKey(1)
    let p2 = testKey(2)
    let p3 = testKey(3)
    for p in [p1, p2, p3]:
      discard rt.insert(p)

    let target = testKey(0x10)
      # stands in for a hashServiceId() result (already in ID space)
    let res = rt.findClosest(target, 3)

    # Expected order uses the *correct* prehashed metric (raw target vs hashed peers).
    # This is what bucketIndex(selfIdPreHashed=true) + the service RegT invariant require.
    var expected = @[p1, p2, p3]
    let hasher = config.hasher
    expected.sort(
      proc(a, b: Key): int =
        cmp(
          xorDistance(a.hashFor(hasher), target), xorDistance(b.hashFor(hasher), target)
        )
    )
    check res == expected

  test "isStale returns true for empty or old keys":
    var bucket: Bucket
    check isStale(bucket) == true

    bucket.peers = @[NodeEntry(nodeId: testKey(1), lastSeen: Moment.now() - 40.minutes)]
    check isStale(bucket) == true

    bucket.peers = @[NodeEntry(nodeId: testKey(1), lastSeen: Moment.now())]
    check isStale(bucket) == false

  test "randomKeyInBucket returns id at correct distance":
    let selfId = testKey(0)
    var rt =
      RoutingTable.new(selfId, RoutingTableConfig.new(hasher = Opt.some(noOpHasher)))
    var rid = randomKeyInBucket(selfId, TargetBucket, rng())
    let idx = rt.bucketIndex(rid)
    check:
      idx == TargetBucket
      rid != selfId

  test "randomKey returns none for empty bucket":
    var bucket: Bucket
    check randomKey(bucket, rng()).isNone()

  test "randomKey returns the only peer in a single-peer bucket":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    let key = randomKeyInBucket(selfId, TargetBucket, rng())
    discard rt.insert(key)

    let picked = randomKey(rt.buckets[TargetBucket], rng())
    check:
      picked.isSome()
      picked.get() == key

  test "randomKey returns a peer from the bucket":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    var keys: seq[Key]
    for _ in 0 ..< config.replication:
      let k = randomKeyInBucket(selfId, TargetBucket, rng())
      keys.add(k)
      discard rt.insert(k)

    let picked = randomKey(rt.buckets[TargetBucket], rng())
    check:
      picked.isSome()
      keys.contains(picked.get())

  test "insert rejects localNodeId even when it differs from selfId":
    let selfId = testKey(0)
    let localNodeId = testKey(99)
    let peer = testKey(1)
    var rt = RoutingTable.new(selfId, localNodeId = Opt.some(localNodeId))

    check:
      not rt.insert(localNodeId) # localNodeId is rejected
      not rt.insert(selfId) # selfId is rejected
      rt.insert(peer) # other peers are accepted

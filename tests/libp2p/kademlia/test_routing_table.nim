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

proc randomTestKey(): Key =
  var buf = newSeqUninit[byte](IdLength)
  rng().generate(buf)
  buf

proc keyWithLeadingZeros(n: int): Key =
  ## Key whose XOR distance to an all-zero selfId under `noOpHasher` has
  ## exactly `n` leading zero bits.
  doAssert n < IdLength * 8, "an all-zero key has no first set bit"
  var buf: array[IdLength, byte]
  buf[n div 8] = 0x80'u8 shr (n mod 8)
  return @buf

suite "KadDHT Routing Table":
  const TargetBucket = 6

  proc keyInBucket(rt: RoutingTable, bucket: int): Key =
    randomKeyInBucket(rt, bucket, rng()).expect("bucket is reachable")

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
      let kid = rt.keyInBucket(TargetBucket)
      discard rt.insert(kid)

    check TargetBucket < rt.buckets.len
    let bucket = rt.buckets[TargetBucket]
    check bucket.peers.len <= config.replication

  proc agePastGrace(rt: RoutingTable, bucketIdx: int) =
    ## Push every peer past the usefulness grace period so eviction can act.
    var bucket = rt.buckets[bucketIdx]
    for i in 0 ..< bucket.peers.len:
      bucket.peers[i].addedAt = Moment.now() - 2.hours
    rt.buckets[bucketIdx] = bucket

  test "evicts oldest replaceable key at max capacity":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    for _ in 0 ..< config.replication + 10:
      let kid = rt.keyInBucket(TargetBucket)
      discard rt.insert(kid)

    check rt.buckets[TargetBucket].peers.len == config.replication

    # Age fresh peers past the grace period so they become evictable.
    rt.agePastGrace(TargetBucket)

    let (oldest, _) = rt.buckets[TargetBucket].oldestPeer()

    check rt.insert(rt.keyInBucket(TargetBucket))

    check:
      rt.buckets[TargetBucket].peers.len == config.replication
      not rt.buckets[TargetBucket].allKeys().contains(oldest.nodeId)

  test "retains peers still within the usefulness grace period":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    for _ in 0 ..< config.replication:
      discard rt.insert(rt.keyInBucket(TargetBucket))

    let before = rt.buckets[TargetBucket].allKeys()
    let newcomer = rt.keyInBucket(TargetBucket)

    # Full of fresh, unproven peers: the newcomer is rejected, none evicted.
    check:
      not rt.insert(newcomer)
      rt.buckets[TargetBucket].allKeys() == before
      not rt.buckets[TargetBucket].allKeys().contains(newcomer)

  test "markUseful protects a peer from eviction":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    for _ in 0 ..< config.replication:
      discard rt.insert(rt.keyInBucket(TargetBucket))

    rt.agePastGrace(TargetBucket)

    # Marking the oldest-seen peer useful spares it and evicts a different one.
    let (oldest, _) = rt.buckets[TargetBucket].oldestPeer()
    rt.markUseful(oldest.nodeId)

    check rt.insert(rt.keyInBucket(TargetBucket))
    check rt.buckets[TargetBucket].allKeys().contains(oldest.nodeId)

  test "re-insert existing key updates lastSeen":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)

    let key1 = rt.keyInBucket(TargetBucket)
    let key2 = rt.keyInBucket(TargetBucket)
    let key3 = rt.keyInBucket(TargetBucket)

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
    let rid = randomKeyInBucket(rt, TargetBucket, rng()).expect("bucket is reachable")
    let idx = rt.bucketIndex(rid)
    check:
      idx == TargetBucket
      rid != selfId

  test "bucketIndex is the prefix length, not a rescale of it":
    let selfId = testKey(0)
    var rt =
      RoutingTable.new(selfId, RoutingTableConfig.new(hasher = Opt.some(noOpHasher)))

    for lz in 0 .. 8:
      check rt.bucketIndex(keyWithLeadingZeros(lz)) == lz

  test "small maxBuckets keeps prefix resolution and saturates the last bucket":
    let selfId = testKey(0)
    const MaxBuckets = 16
    var rt = RoutingTable.new(
      selfId,
      RoutingTableConfig.new(hasher = Opt.some(noOpHasher), maxBuckets = MaxBuckets),
    )

    # Prefix lengths below the cap each get their own bucket.
    for lz in 0 ..< MaxBuckets - 1:
      check rt.bucketIndex(keyWithLeadingZeros(lz)) == lz

    # Deeper prefixes all fall into the last bucket.
    for lz in MaxBuckets - 1 .. MaxBuckets + 8:
      check rt.bucketIndex(keyWithLeadingZeros(lz)) == MaxBuckets - 1

  test "randomKeyInBucket targets the bucket under the default (hashing) hasher":
    # The bucket of a key is decided by its *hash*, so a target built by
    # manipulating selfId's bits lands in an unrelated bucket once hashed.
    let selfId = testKey(0)
    var rt = RoutingTable.new(selfId, RoutingTableConfig.new())

    for bucket in [0, 1, TargetBucket, MaxRefreshLeadingZeros]:
      for _ in 0 ..< 5:
        let rid = randomKeyInBucket(rt, bucket, rng()).expect("bucket is reachable")
        check rt.bucketIndex(rid) == bucket

  test "randomKeyInBucket returns none for buckets too near to search for":
    let selfId = testKey(0)
    var rt = RoutingTable.new(selfId, RoutingTableConfig.new())

    check randomKeyInBucket(rt, MaxRefreshLeadingZeros + 1, rng()).isNone()

  test "randomKeyInBucket respects a narrow bucket split":
    # Service-discovery tables split the id space into few buckets.
    const MaxBuckets = 16
    let selfId = testKey(0)
    var rt = RoutingTable.new(selfId, RoutingTableConfig.new(maxBuckets = MaxBuckets))

    for bucket in 0 .. MaxRefreshLeadingZeros:
      let rid = randomKeyInBucket(rt, bucket, rng()).expect("bucket is reachable")
      check rt.bucketIndex(rid) == bucket

    # The last bucket needs 15 shared prefix bits — beyond the cap.
    check randomKeyInBucket(rt, MaxBuckets - 1, rng()).isNone()

  test "refreshTarget falls back to a peer of a bucket too near to search for":
    # Buckets past the cap share too long a prefix with selfId to draw at random.
    const NearBucket = MaxRefreshLeadingZeros + 1
    let selfId = testKey(0)
    var rt = RoutingTable.new(selfId, RoutingTableConfig.new())

    var inserted: seq[Key]
    while inserted.len < 3:
      let key = randomTestKey()
      if rt.bucketIndex(key) != NearBucket:
        continue
      discard rt.insert(key)
      inserted.add(key)

    check randomKeyInBucket(rt, NearBucket, rng()).isNone()

    let target = rt.refreshTarget(NearBucket, rng()).expect("bucket holds peers")
    check:
      target in inserted
      rt.bucketIndex(target) == NearBucket

  test "refreshTarget returns none for an unreachable empty bucket":
    let selfId = testKey(0)
    var rt = RoutingTable.new(selfId, RoutingTableConfig.new())

    check rt.refreshTarget(MaxRefreshLeadingZeros + 1, rng()).isNone()

  test "refreshTarget prefers a random key when the bucket is reachable":
    let selfId = testKey(0)
    var rt = RoutingTable.new(selfId, RoutingTableConfig.new())
    let peer = rt.keyInBucket(TargetBucket)
    discard rt.insert(peer)

    let target = rt.refreshTarget(TargetBucket, rng()).expect("bucket is reachable")
    check:
      target != peer
      rt.bucketIndex(target) == TargetBucket

  test "randomKey returns none for empty bucket":
    var bucket: Bucket
    check randomKey(bucket, rng()).isNone()

  test "randomKey returns the only peer in a single-peer bucket":
    let selfId = testKey(0)
    let config = RoutingTableConfig.new(hasher = Opt.some(noOpHasher))
    var rt = RoutingTable.new(selfId, config)
    let key = rt.keyInBucket(TargetBucket)
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
      let k = rt.keyInBucket(TargetBucket)
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

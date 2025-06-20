{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import unittest
import chronos
import ../../libp2p/crypto/crypto
import ../../libp2p/protocols/kademlia/[routingtable, consts, keys]

proc testKey*(x: byte): Key =
  var buf: array[IdLength, byte]
  buf[31] = x
  return Key(kind: KeyType.Unhashed, data: buf)

let rng = crypto.newRng()

suite "routing table":
  test "inserts single key in correct bucket":
    let selfId = testKey(0)
    var rt = RoutingTable.init(selfId)
    let other = testKey(0b10000000)
    discard rt.insert(other)

    let idx = bucketIndex(selfId, other)
    check:
      rt.buckets.len > idx
      rt.buckets[idx].peers.len == 1
      rt.buckets[idx].peers[0].nodeId == other

  test "does not insert beyond capacity":
    let selfId = testKey(0)
    var rt = RoutingTable.init(selfId)
    let targetBucket = 6
    for _ in 0 ..< k + 5:
      var kid = randomKeyInBucketRange(selfId, targetBucket, rng)
      kid.kind = KeyType.Unhashed
        # Overriding so we don't use sha for comparing xor distances
      discard rt.insert(kid)

    check targetBucket < rt.buckets.len
    let bucket = rt.buckets[targetBucket]
    check bucket.peers.len <= k

  test "findClosest returns sorted keys":
    let selfId = testKey(0)
    var rt = RoutingTable.init(selfId)
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

  test "randomKeyInBucketRange returns id at correct distance":
    let selfId = testKey(0)
    let targetBucket = 3
    var rid = randomKeyInBucketRange(selfId, targetBucket, rng)
    rid.kind = KeyType.Unhashed
      # Overriding so we don't use sha for comparing xor distances
    let idx = bucketIndex(selfId, rid)
    check:
      idx == targetBucket
      rid != selfId

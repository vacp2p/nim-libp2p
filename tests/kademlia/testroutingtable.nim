import unittest, sequtils
import chronos
import ../../libp2p/peerid
import ../../libp2p/crypto/crypto
import ../../libp2p/protocols/kademlia/[routingtable, consts]

proc tPeerId*(x: byte): PeerId =
  var buf = newSeqWith(32, 0'u8)
  buf[31] = x
  return PeerId(data: buf)

suite "routing table":
  test "insert single peer in correct bucket":
    let selfId = tPeerId(0)
    var rt = RoutingTable.init(selfId)
    let other = tPeerId(0b10000000)
    rt.insert(other)

    let idx = bucketIndex(selfId, other)
    check rt.buckets.len > idx
    check rt.buckets[idx].peers.len == 1
    check rt.buckets[idx].peers[0].peerId == other

  test "does not insert beyond capacity":
    let selfId = tPeerId(0)
    var rt = RoutingTable.init(selfId)
    let targetBucket = 6
    for _ in 0 ..< k + 5:
      let rng = crypto.newRng()
      let peerId = randomIdInBucketRange(selfId, targetBucket, rng)
      rt.insert(peerId)

    check targetBucket < rt.buckets.len
    let bucket = rt.buckets[targetBucket]
    check bucket.peers.len <= k

  test "findClosest returns sorted peers":
    let selfId = tPeerId(0)
    var rt = RoutingTable.init(selfId)
    let ids = @[tPeerId(1), tPeerId(2), tPeerId(3), tPeerId(4), tPeerId(5)]
    for id in ids:
      rt.insert(id)

    let res = rt.findClosest(tPeerId(1), 3)

    check res.len == 3
    check res[0] == tPeerId(1)

  test "isStale returns true for empty or old peers":
    var bucket: Bucket
    check isStale(bucket) == true

    bucket.peers = @[PeerEntry(peerId: tPeerId(1), lastSeen: Moment.now() - 40.minutes)]
    check isStale(bucket) == true

    bucket.peers = @[PeerEntry(peerId: tPeerId(1), lastSeen: Moment.now())]
    check isStale(bucket) == false

  test "randomIdInBucketRange returns id at correct distance":
    let selfId = tPeerId(0)
    let targetBucket = 3
    let rng = crypto.newRng()
    let rid = randomIdInBucketRange(selfId, targetBucket, rng)
    let idx = bucketIndex(selfId, rid)
    check idx == targetBucket

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import algorithm, sequtils
import chronos, chronicles, results
import ./types
import ./kademlia_metrics
import ../../peerid
import ../../crypto/crypto

logScope:
  topics = "kad-dht rtable"

const NoneHasher = Opt.none(XorDHasher)

proc new*(
    T: typedesc[RoutingTableConfig],
    replication = DefaultReplication,
    hasher: Opt[XorDHasher] = NoneHasher,
    maxBuckets: int = DefaultMaxBuckets,
    selfIdPreHashed = false,
): T =
  RoutingTableConfig(
    replication: replication,
    hasher: hasher,
    maxBuckets: maxBuckets,
    selfIdPreHashed: selfIdPreHashed,
  )

proc `$`*(rt: RoutingTable): string =
  "selfId(" & $rt.selfId & ") buckets(" & $rt.buckets & ")"

proc new*(
    T: typedesc[RoutingTable],
    selfId: Key,
    config: RoutingTableConfig = RoutingTableConfig.new(),
    localNodeId: Opt[Key] = Opt.none(Key),
): T =
  RoutingTable(
    selfId: selfId, localNodeId: localNodeId.get(selfId), buckets: @[], config: config
  )

proc bucketIndex*(
    selfId, key: Key,
    hasher: Opt[XorDHasher],
    maxBuckets: int = DefaultMaxBuckets,
    selfIdPreHashed = false,
): int =
  let
    selfHash =
      if selfIdPreHashed:
        selfId
      else:
        selfId.hashFor(hasher)
    keyHash = key.hashFor(hasher)
    lz = xorDistance(selfHash, keyHash).leadingZeros

  if maxBuckets <= 1:
    return 0

  return min(((lz * maxBuckets) div 256), maxBuckets - 1)

proc peerIndexInBucket(bucket: Bucket, nodeId: Key): Opt[int] =
  for i, p in bucket.peers:
    if p.nodeId == nodeId:
      return Opt.some(i)
  return Opt.none(int)

proc oldestPeer*(bucket: Bucket): (NodeEntry, int) =
  var oldestIdx = 0
  var oldest = bucket.peers[0]
  for i, p in bucket.peers:
    if p.lastSeen < oldest.lastSeen:
      oldest = p
      oldestIdx = i
  (oldest, oldestIdx)

proc replaceOldest(bucket: var Bucket, newNodeId: Key, replication: int): bool =
  if bucket.peers.len < replication:
    trace "Skipping replace: bucket is not full", newNodeId = newNodeId
    return false

  let (oldest, oldestIdx) = bucket.oldestPeer()

  if oldest.nodeId == newNodeId:
    trace "Failed to replace: same nodeId", newNodeId = newNodeId
    return false

  bucket.peers[oldestIdx] = NodeEntry(nodeId: newNodeId, lastSeen: Moment.now())
  true

proc updateRoutingTableMetrics*(rtable: RoutingTable) =
  ## Update routing table gauge metrics
  var total = 0
  for i, b in rtable.buckets:
    total += b.peers.len
    # Only track non-empty buckets to reduce cardinality
    if b.peers.len > 0:
      kad_routing_table_bucket_size.set(b.peers.len.float64, labelValues = [$i])
  kad_routing_table_peers.set(total.float64)
  kad_routing_table_buckets.set(rtable.buckets.len.float64)

proc insert*(rtable: RoutingTable, nodeId: Key): bool =
  if nodeId == rtable.selfId or nodeId == rtable.localNodeId:
    debug "Cannot insert self in routing table", nodeId = nodeId
    return false # No self insertion

  let idx = bucketIndex(
    rtable.selfId, nodeId, rtable.config.hasher, rtable.config.maxBuckets,
    rtable.config.selfIdPreHashed,
  )

  if idx >= rtable.buckets.len:
    # expand buckets lazily if needed
    rtable.buckets.setLen(idx + 1)

  var bucket = rtable.buckets[idx]
  let keyx = peerIndexInBucket(bucket, nodeId)
  if keyx.isSome:
    bucket.peers[keyx.unsafeValue].lastSeen = Moment.now()
  elif bucket.peers.len < rtable.config.replication:
    bucket.peers.add(NodeEntry(nodeId: nodeId, lastSeen: Moment.now()))
    kad_routing_table_insertions.inc()
  else:
    # eviction policy: replace oldest key
    if not bucket.replaceOldest(nodeId, rtable.config.replication):
      debug "Cannot insert, failed to replace oldest key in bucket",
        bucket = idx, nodeId = nodeId
      return false
    kad_routing_table_replacements.inc()

  rtable.buckets[idx] = bucket
  updateRoutingTableMetrics(rtable)
  return true

proc insert*(rtable: RoutingTable, peerId: PeerId): bool =
  insert(rtable, peerId.toKey())

proc findClosest*(rtable: RoutingTable, targetId: Key, count: int): seq[Key] =
  ## Returns up to `count` nodes in the table with the smallest XOR distance to `targetId`.
  var allNodes: seq[Key] = @[]

  for bucket in rtable.buckets:
    for p in bucket.peers:
      allNodes.add(p.nodeId)

  let hasher = rtable.config.hasher
  let targetHash =
    if rtable.config.selfIdPreHashed:
      targetId
    else:
      targetId.hashFor(hasher)

  allNodes.sort(
    proc(a, b: Key): int =
      cmp(
        xorDistance(a.hashFor(hasher), targetHash),
        xorDistance(b.hashFor(hasher), targetHash),
      )
  )

  return allNodes[0 ..< min(count, allNodes.len)]

proc findClosestPeerIds*(rtable: RoutingTable, targetId: Key, count: int): seq[PeerId] =
  return findClosest(rtable, targetId, count)
    .mapIt(it.toPeerId())
    .filterIt(it.isOk)
    .mapIt(it.value())

proc randomPeersClosestFirst*(
    rtable: RoutingTable, rng: Rng, count: int, maxPerBucket = high(int)
): seq[Key] =
  ## Returns up to `count` peers sampled randomly from the routing table's
  ## buckets, starting from the closest buckets (highest indices) and moving
  ## to farther buckets (lower indices).

  if count <= 0:
    return @[]

  var selected: seq[Key] = @[]
  var remaining = count

  for i in countdown(rtable.buckets.high, 0):
    if remaining <= 0:
      break
    let bucket = rtable.buckets[i]
    if bucket.peers.len == 0:
      continue

    let take = min(remaining, min(maxPerBucket, bucket.peers.len))
    let picked = rng.pick(bucket.peers, take).valueOr(@[])
    for entry in picked:
      selected.add(entry.nodeId)
      remaining.dec
      if remaining <= 0:
        break

  return selected

proc randomPeersClosestFirstPeerIds*(
    rtable: RoutingTable, rng: Rng, count: int, maxPerBucket = high(int)
): seq[PeerId] =
  randomPeersClosestFirst(rtable, rng, count, maxPerBucket)
    .mapIt(it.toPeerId())
    .filterIt(it.isOk)
    .mapIt(it.value())

proc isStale*(bucket: Bucket): bool =
  if bucket.peers.len == 0:
    return true
  for p in bucket.peers:
    if Moment.now() - p.lastSeen > DefaultBucketStaleTime:
      return true
  return false

proc randomKeyInBucket*(
    selfId: Key, bucketIndex: int, rng: Rng, maxBuckets: int = DefaultMaxBuckets
): Key =
  let targetLz =
    if maxBuckets <= 1:
      0
    elif maxBuckets == 256 or bucketIndex >= maxBuckets:
      bucketIndex
    else:
      let M = maxBuckets
      # lz in [lo, hi] satisfy (lz * M) div 256 == bucketIndex
      let lo = (bucketIndex * 256 + M - 1) div M
      let hi = min(256, ((bucketIndex + 1) * 256 + M - 1) div M - 1)
      if lo > hi:
        bucketIndex * (256 div max(1, M))
      else:
        let span = hi - lo + 1
        var r: array[1, byte]
        rng.generate(r)
        lo + (int(r[0]) mod span)

  var raw = selfId

  for i in 0 ..< targetLz:
    let byteIdx = i div 8
    let bitInByte = 7 - (i mod 8)
    raw[byteIdx] = raw[byteIdx] and not (1'u8 shl bitInByte)

  # flip the target bit
  let tgtByte = targetLz div 8
  let tgtBitInByte = 7 - (targetLz mod 8)
  raw[tgtByte] = raw[tgtByte] xor (1'u8 shl tgtBitInByte)

  # randomize lower bits of the boundary byte
  let lsbMask = (1'u8 shl tgtBitInByte) - 1
  if lsbMask != 0:
    var rb: array[1, byte]
    rng.generate(rb)
    raw[tgtByte] = (raw[tgtByte] and not lsbMask) or (rb[0] and lsbMask)

  # randomize remaining bytes
  if tgtByte + 1 < raw.len:
    rng.generate(raw.toOpenArray(tgtByte + 1, raw.len - 1))

  return raw

proc allKeys*(bucket: Bucket): seq[Key] {.inline.} =
  return bucket.peers.mapIt(it.nodeId)

proc allKeys*(rtable: RoutingTable): seq[Key] {.inline.} =
  rtable.buckets.mapIt(it.allKeys()).concat()

proc randomKey*(bucket: Bucket, rng: Rng): Opt[Key] =
  rng.pickOne(bucket.peers).map(
    proc(e: NodeEntry): Key =
      e.nodeId
  )

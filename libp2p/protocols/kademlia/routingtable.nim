# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import algorithm, sequtils
import bearssl/rand, chronos, chronicles, results
import ./types
import ./kademlia_metrics
import ../../peerid
import ../../utils/sequninit

logScope:
  topics = "kad-dht rtable"

const NoneHasher = Opt.none(XorDHasher)

proc new*(
    T: typedesc[RoutingTableConfig],
    replication = DefaultReplication,
    hasher: Opt[XorDHasher] = NoneHasher,
    maxBuckets: int = DefaultMaxBuckets,
    purgeStaleEntries: bool = false,
): T =
  RoutingTableConfig(
    replication: replication,
    hasher: hasher,
    maxBuckets: maxBuckets,
    purgeStaleEntries: purgeStaleEntries,
  )

proc `$`*(rt: RoutingTable): string =
  "selfId(" & $rt.selfId & ") buckets(" & $rt.buckets & ")"

proc new*(
    T: typedesc[RoutingTable],
    selfId: Key,
    config: RoutingTableConfig = RoutingTableConfig.new(),
): T =
  RoutingTable(selfId: selfId, buckets: @[], config: config)

proc bucketIndex*(selfId, key: Key, hasher: Opt[XorDHasher]): int =
  return xorDistance(selfId, key, hasher).leadingZeros

proc peerIndexInBucket(bucket: var Bucket, nodeId: Key): Opt[int] =
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

proc insert*(rtable: var RoutingTable, nodeId: Key): bool =
  if nodeId == rtable.selfId:
    debug "Cannot insert self in routing table", nodeId = nodeId
    return false # No self insertion

  let idx = bucketIndex(rtable.selfId, nodeId, rtable.config.hasher)
  if idx >= rtable.config.maxBuckets:
    debug "Cannot insert node, max buckets have been reached",
      nodeId = nodeId, bucketIdx = idx, maxBuckets = rtable.config.maxBuckets
    return false

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

proc insert*(rtable: var RoutingTable, peerId: PeerId): bool =
  insert(rtable, peerId.toKey())

proc findClosest*(rtable: RoutingTable, targetId: Key, count: int): seq[Key] =
  var allNodes: seq[Key] = @[]

  for bucket in rtable.buckets:
    for p in bucket.peers:
      allNodes.add(p.nodeId)

  allNodes.sort(
    proc(a, b: Key): int =
      cmp(
        xorDistance(a, targetId, rtable.config.hasher),
        xorDistance(b, targetId, rtable.config.hasher),
      )
  )

  return allNodes[0 ..< min(count, allNodes.len)]

proc findClosestPeerIds*(rtable: RoutingTable, targetId: Key, count: int): seq[PeerId] =
  return findClosest(rtable, targetId, count)
    .mapIt(it.toPeerId())
    .filterIt(it.isOk)
    .mapIt(it.value())

proc purgeExpired*(rtable: var RoutingTable) =
  ## Remove entries from all buckets that have not been refreshed within
  ## DefaultBucketStaleTime. No-op if purgeStaleEntries is false.
  if not rtable.config.purgeStaleEntries:
    return

  let now = Moment.now()
  var totalPurged = 0
  for i in 0 ..< rtable.buckets.len:
    let before = rtable.buckets[i].peers.len
    rtable.buckets[i].peers.keepItIf(now - it.lastSeen <= DefaultBucketStaleTime)
    let purged = before - rtable.buckets[i].peers.len
    if purged > 0:
      debug "Purged stale routing table entries", bucketIdx = i, count = purged
      totalPurged += purged

  if totalPurged > 0:
    kad_routing_table_replacements.inc(totalPurged)
    updateRoutingTableMetrics(rtable)

proc isStale*(bucket: Bucket): bool =
  if bucket.peers.len == 0:
    return true
  for p in bucket.peers:
    if Moment.now() - p.lastSeen > DefaultBucketStaleTime:
      return true
  return false

proc randomKeyInBucket*(selfId: Key, bucketIndex: int, rng: var HmacDrbgContext): Key =
  var raw = selfId

  # zero out higher bits
  for i in 0 ..< bucketIndex:
    let byteIdx = i div 8
    let bitInByte = 7 - (i mod 8)
    raw[byteIdx] = raw[byteIdx] and not (1'u8 shl bitInByte)

  # flip the target bit
  let tgtByte = bucketIndex div 8
  let tgtBitInByte = 7 - (bucketIndex mod 8)
  raw[tgtByte] = raw[tgtByte] xor (1'u8 shl tgtBitInByte)

  # randomize all less significant bits
  let totalBits = raw.len * 8
  let lsbStart = bucketIndex + 1
  let lsbBytes = (totalBits - lsbStart + 7) div 8
  var randomBuf = newSeqUninit[byte](lsbBytes)
  rng.hmacDrbgGenerate(randomBuf)

  for i in lsbStart ..< totalBits:
    let byteIdx = i div 8
    let bitInByte = 7 - (i mod 8)
    let lsbByte = (i - lsbStart) div 8
    let lsbBit = 7 - ((i - lsbStart) mod 8)
    let randBit = (randomBuf[lsbByte] shr lsbBit) and 1
    if randBit == 1:
      raw[byteIdx] = raw[byteIdx] or (1'u8 shl bitInByte)
    else:
      raw[byteIdx] = raw[byteIdx] and not (1'u8 shl bitInByte)

  return raw

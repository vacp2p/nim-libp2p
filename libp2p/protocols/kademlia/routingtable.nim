import algorithm, sequtils
import bearssl/rand, chronos, chronicles, results
import ./types
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
): T =
  RoutingTableConfig(replication: replication, hasher: hasher, maxBuckets: maxBuckets)

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

proc insert*(rtable: var RoutingTable, nodeId: Key): bool =
  if nodeId == rtable.selfId:
    return false # No self insertion

  let idx = bucketIndex(rtable.selfId, nodeId, rtable.config.hasher)
  if idx >= rtable.config.maxBuckets:
    trace "Cannot insert node, max buckets have been reached",
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
  else:
    # eviction policy: replace oldest key
    if not bucket.replaceOldest(nodeId, rtable.config.replication):
      return false

  rtable.buckets[idx] = bucket
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

proc isStale*(bucket: Bucket): bool =
  if bucket.peers.len == 0:
    return true
  for p in bucket.peers:
    if Moment.now() - p.lastSeen > 30.minutes:
      return true
  return false

proc randomKeyInBucketRange*(
    selfId: Key, bucketIndex: int, rng: ref HmacDrbgContext
): Key =
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
  hmacDrbgGenerate(rng[], randomBuf)

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

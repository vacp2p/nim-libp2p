import algorithm
import bearssl/rand
import chronos
import chronicles
import ./consts
import ./keys
import ./xordistance
import ../../peerid
import sequtils

logScope:
  topics = "kad-dht rtable"

type
  NodeEntry* = object
    nodeId*: Key
    lastSeen*: Moment

  Bucket* = object
    peers*: seq[NodeEntry]

  RoutingTable* = ref object
    selfId*: Key
    buckets*: seq[Bucket]

proc `$`*(rt: RoutingTable): string =
  "selfId(" & $rt.selfId & ") buckets(" & $rt.buckets & ")"

proc init*(T: typedesc[RoutingTable], selfId: Key): T =
  return RoutingTable(selfId: selfId, buckets: @[])

proc bucketIndex*(selfId, key: Key): int =
  return xorDistance(selfId, key).leadingZeros

proc peerIndexInBucket(bucket: var Bucket, nodeId: Key): Opt[int] =
  for i, p in bucket.peers:
    if p.nodeId == nodeId:
      return Opt.some(i)
  return Opt.none(int)

proc insert*(rtable: var RoutingTable, nodeId: Key): bool =
  if nodeId == rtable.selfId:
    return false # No self insertion

  let idx = bucketIndex(rtable.selfId, nodeId)
  if idx >= maxBuckets:
    trace "cannot insert node. max buckets have been reached",
      nodeId, bucketIdx = idx, maxBuckets
    return false

  if idx >= rtable.buckets.len:
    # expand buckets lazily if needed
    rtable.buckets.setLen(idx + 1)

  var bucket = rtable.buckets[idx]
  let keyx = peerIndexInBucket(bucket, nodeId)
  if keyx.isSome:
    bucket.peers[keyx.unsafeValue].lastSeen = Moment.now()
  elif bucket.peers.len < k:
    bucket.peers.add(NodeEntry(nodeId: nodeId, lastSeen: Moment.now()))
  else:
    # TODO: eviction policy goes here, rn we drop the node
    trace "cannot insert node in bucket, dropping node",
      nodeId, bucket = k, bucketIdx = idx
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
      cmp(xorDistance(a, targetId), xorDistance(b, targetId))
  )

  return allNodes[0 ..< min(count, allNodes.len)]

proc findClosestPeers*(rtable: RoutingTable, targetId: Key, count: int): seq[PeerId] =
  findClosest(rtable, targetId, count).mapIt(it.peerId)

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
  var raw = selfId.getBytes()

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
  var randomBuf = newSeqUninitialized[byte](lsbBytes)
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

  return raw.toKey()

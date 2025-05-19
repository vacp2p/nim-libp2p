import algorithm
import bearssl/rand
import chronos
import ./consts
import ../../peerid
import ./xordistance

type
  PeerEntry* = object
    peerId*: PeerId
    lastSeen*: Moment

  Bucket* = object
    peers*: seq[PeerEntry]

  RoutingTable* = object
    selfId*: PeerId
    buckets*: seq[Bucket]

proc bucketIndex*(selfId, peerId: PeerId): int =
  let distance = xorDistance(selfId, peerId)
  return distance.leadingZeros

proc findPeer(bucket: var Bucket, peerId: PeerId): int =
  for i, p in bucket.peers:
    if p.peerId == peerId:
      return i
  return -1

proc insert*(rtable: var RoutingTable, peerId: PeerId) =
  if peerId == rtable.selfId:
    return # No self insertion

  let idx = bucketIndex(rtable.selfId, peerId)
  if idx >= maxBuckets:
    return # TODO: log?

  if idx >= rtable.buckets.len:
    # expand buckets lazily if needed
    rtable.buckets.setLen(idx + 1)

  var bucket = rtable.buckets[idx]
  let i = findPeer(bucket, peerId)
  if i != -1:
    bucket.peers[i].lastSeen = Moment.now()
  else:
    if bucket.peers.len < k:
      bucket.peers.add PeerEntry(peerId: peerId, lastSeen: Moment.now())
    else:
      discard # eviction policy goes here, rn we drop

  rtable.buckets[idx] = bucket

proc findClosest*(rtable: RoutingTable, targetId: PeerId, count: int): seq[PeerId] =
  var allPeers: seq[PeerId] = @[]

  for bucket in rtable.buckets:
    for p in bucket.peers:
      allPeers.add(p.peerId)

  allPeers.sort(
    proc(a, b: PeerId): int =
      cmp(xorDistance(a, targetId), xorDistance(b, targetId))
  )

  return allPeers[0 ..< min(count, allPeers.len)]

proc isStale*(bucket: Bucket): bool =
  if bucket.peers.len == 0:
    return true
  for p in bucket.peers:
    if Moment.now() - p.lastSeen > 30.minutes:
      return true
  return false

proc randomIdInBucketRange*(
    selfId: PeerId, bucketIndex: int, rng: ref HmacDrbgContext
): PeerId =
  var raw = selfId.getBytes()

  # zero higher bits
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
  var randomBuf = newSeq[byte](lsbBytes)
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

  return PeerId(data: raw)

proc init*(T: typedesc[RoutingTable], selfId: PeerId): T =
  return RoutingTable(selfId: selfId, buckets: @[])

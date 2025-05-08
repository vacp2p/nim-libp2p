import algorithm
import random
import chronos
import ./consts
import ../../peerid
import ./xordistance

type
  PeerEntry = object
    peerId: PeerId
    lastSeen*: Moment

  Bucket = object
    peers*: seq[PeerEntry]

  RoutingTable* = object
    selfId*: PeerId
    buckets*: seq[Bucket]

proc bucketIndex(selfId, peerId: PeerId): int =
  let distance = xorDistance(selfId, peerId)
  return distance.leadingZeros

proc insert*(rtable: var RoutingTable, peerId: PeerId) =
  let idx = bucketIndex(rtable.selfId, peerId)
  if idx >= rtable.buckets.len:
    # expand buckets lazily if needed
    rtable.buckets.setLen(idx + 1)

  var bucket = rtable.buckets[idx]

  # if peer already there, update lastSeen
  for p in mitems(bucket.peers):
    if p.peerId == peerId:
      p.lastSeen = Moment.now()
      return

  # otherwise insert
  if bucket.peers.len < k:
    bucket.peers.add(PeerEntry(peerId: peerId, lastSeen: Moment.now()))
  else:
    # bucket full, could implement ping-oldest-before-evict here ?
    discard

proc findClosest*(rtable: RoutingTable, targetId: PeerId, count: int): seq[PeerId] =
  var allPeers: seq[PeerId] = @[]

  for bucket in rtable.buckets:
    for p in bucket.peers:
      allPeers.add(p.peerId)

  allPeers.sort(
    proc(a, b: PeerId): int =
      cmp(xorDistance(b, targetId), xorDistance(a, targetId))
  )

  return allPeers[0 ..< min(count, allPeers.len)]

proc isStale*(bucket: Bucket): bool =
  if bucket.peers.len == 0:
    return true
  for p in bucket.peers:
    if Moment.now() - p.lastSeen > 30.minutes:
      return true
  return false

proc flipBit(id: var seq[byte], bitIndex: int) =
  let byteIndex = bitIndex div 8
  let bitInByte = 7 - (bitIndex mod 8)
  id[byteIndex] = id[byteIndex] xor (1'u8 shl bitInByte)

proc randomizeLowerBits*(id: var seq[byte], bitIndex: int) =
  let byteStart = (bitIndex + 1) div 8
  for i in byteStart ..< id.len:
    id[i] = rand(255).uint8 # TODO: rng

proc randomIdInBucketRange*(selfId: PeerId, bucketIndex: int): PeerId =
  var rawId = selfId.getBytes()
  flipBit(rawId, bucketIndex) # flip the bit corresponding to bucket range
  randomizeLowerBits(rawId, bucketIndex)
  return PeerId(data: rawId)

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[tables, sequtils, sets]
from times import now
import chronos, chronicles, results, sugar, stew/arrayOps, nimcrypto/sha2
import ../protocol
import ../../[peerid, switch, multihash]
import ./protobuf

const
  IdLength* = 32 # 256-bit IDs

  DefaultMaxBuckets* = 256
  DefaultTimeout* = 5.seconds
  DefaultRetries* = 5
  DefaultReplication* = 20 ## aka `k` in the spec
  DefaultAlpha* = 10 # concurrency parameter
  DefaultTTL* = 24.hours
  DefaultQuorum* = 5 # number of GetValue responses needed to decide

  KadCodec* = "/ipfs/kad/1.0.0"
  MaxMsgSize* = 4096

type Key* = seq[byte]

proc isValid*(k: Key): bool =
  return k.len > 0 and k.len < 80

proc toKey*(p: PeerId): Key =
  return Key(p.data)

proc toPeerId*(k: Key): Result[PeerId, string] =
  PeerId.init(k).mapErr(x => $x)

proc toPeer*(k: Key, switch: Switch): Result[Peer, string] =
  let peer = ?k.toPeerId()
  let addrs = switch.peerStore[AddressBook][peer]
  if addrs.len == 0:
    return err("Could not find peer addresses in address book")

  ok(
    Peer(
      id: peer.getBytes(),
      addrs: addrs,
      connection:
        # TODO: this should likely be optional as it can reveal the network graph of a node
        if switch.isConnected(peer):
          ConnectionType.connected
        else:
          ConnectionType.notConnected,
    )
  )

proc toPeer*(peerInfo: PeerInfo): Peer =
  Peer(
    id: peerInfo.peerId.getBytes(),
    addrs: peerInfo.addrs,
    connection: ConnectionType.connected,
  )

proc shortLog*(k: Key): string =
  "key:" & toHex(k)

chronicles.formatIt(Key):
  shortLog(it)

type XorDistance* = array[IdLength, byte]
type XorDHasher* = proc(input: seq[byte]): array[IdLength, byte] {.
  raises: [], nimcall, noSideEffect, gcsafe
.}

proc defaultHasher(
    input: seq[byte]
): array[IdLength, byte] {.raises: [], nimcall, noSideEffect, gcsafe.} =
  return sha256.digest(input).data

# useful for testing purposes
proc noOpHasher*(
    input: seq[byte]
): array[IdLength, byte] {.raises: [], nimcall, noSideEffect, gcsafe.} =
  var data: array[IdLength, byte]
  discard data.copyFrom(input)
  return data

proc countLeadingZeroBits*(b: byte): int =
  for i in 0 .. 7:
    if (b and (0x80'u8 shr i)) != 0:
      return i
  return 8

proc leadingZeros*(dist: XorDistance): int =
  for i in 0 ..< dist.len:
    if dist[i] != 0:
      return i * 8 + countLeadingZeroBits(dist[i])
  return dist.len * 8

proc cmp*(a, b: XorDistance): int =
  for i in 0 ..< IdLength:
    if a[i] < b[i]:
      return -1
    elif a[i] > b[i]:
      return 1
  return 0

proc `<`*(a, b: XorDistance): bool =
  cmp(a, b) < 0

proc `<=`*(a, b: XorDistance): bool =
  cmp(a, b) <= 0

proc hashFor(k: Key, hasher: Opt[XorDHasher]): seq[byte] =
  return @(hasher.get(defaultHasher)(k))

proc xorDistance*(a, b: Key, hasher: Opt[XorDHasher]): XorDistance =
  let hashA = a.hashFor(hasher)
  let hashB = b.hashFor(hasher)
  var response: XorDistance
  for i in 0 ..< hashA.len:
    response[i] = hashA[i] xor hashB[i]
  return response

proc xorDistance*(a: PeerId, b: Key, hasher: Opt[XorDHasher]): XorDistance =
  xorDistance(a.toKey(), b, hasher)

proc xorDistance*(a: Key, b: PeerId, hasher: Opt[XorDHasher]): XorDistance =
  xorDistance(a, b.toKey(), hasher)

proc xorDistance*(a, b: PeerId, hasher: Opt[XorDHasher]): XorDistance =
  xorDistance(a.toKey(), b.toKey(), hasher)

type
  NodeEntry* = object
    nodeId*: Key
    lastSeen*: Moment

  Bucket* = object
    peers*: seq[NodeEntry]

  RoutingTableConfig* = ref object
    replication*: int
    hasher*: Opt[XorDHasher]
    maxBuckets*: int

  RoutingTable* = ref object
    selfId*: Key
    buckets*: seq[Bucket]
    config*: RoutingTableConfig

## Currently a string, because for some reason, that's what is chosen at the protobuf level
## TODO: convert between RFC3339 strings and use of integers (i.e. the _correct_ way)
type TimeStamp* = string

type EntryRecord* = object
  value*: seq[byte]
  time*: TimeStamp

proc init*(
    T: typedesc[EntryRecord], value: Key, time: Opt[TimeStamp]
): EntryRecord {.gcsafe, raises: [].} =
  EntryRecord(value: value, time: time.get(TimeStamp(ts: $times.now().utc)))

type
  ReceivedTable* = TableRef[PeerId, Opt[EntryRecord]]
  CandidatePeers* = ref HashSet[PeerId]
  LocalTable* = Table[Key, EntryRecord]

proc insert*(
    self: var LocalTable, key: Key, value: sink seq[byte], time: TimeStamp
) {.raises: [].} =
  debug "Local table insertion", key = key, value = value
  self[key] = EntryRecord(value: value, time: time)

proc get*(self: LocalTable, key: Key): Opt[EntryRecord] {.raises: [].} =
  if not self.hasKey(key):
    return Opt.none(EntryRecord)
  try:
    return Opt.some(self[key])
  except KeyError:
    doAssert false, "checked with hasKey"

type EntryValidator* = ref object of RootObj
method isValid*(
    self: EntryValidator, key: Key, record: EntryRecord
): bool {.base, raises: [], gcsafe.} =
  doAssert(false, "EntryValidator base not implemented")

type EntrySelector* = ref object of RootObj
method select*(
    self: EntrySelector, key: Key, records: seq[EntryRecord]
): Result[int, string] {.base, raises: [], gcsafe.} =
  doAssert(false, "EntrySelection base not implemented")

type DefaultEntryValidator* = ref object of EntryValidator
method isValid*(
    self: DefaultEntryValidator, key: Key, record: EntryRecord
): bool {.raises: [], gcsafe.} =
  return true

type DefaultEntrySelector* = ref object of EntrySelector
method select*(
    self: DefaultEntrySelector, key: Key, records: seq[EntryRecord]
): Result[int, string] {.raises: [], gcsafe.} =
  if records.len == 0:
    return err("No records to choose from")

  # Map value -> (count, firstIndex)
  var counts: Table[seq[byte], (int, int)]
  for i, v in records.mapIt(it.value):
    try:
      let (cnt, idx) = counts[v]
      counts[v] = (cnt + 1, idx)
    except KeyError:
      counts[v] = (1, i)

  # Find the first value with the highest count
  var bestIdx = 0
  var maxCount = -1
  var minFirstIdx = high(int)
  for _, (cnt, idx) in counts.pairs:
    if cnt > maxCount or (cnt == maxCount and idx < minFirstIdx):
      maxCount = cnt
      bestIdx = idx
      minFirstIdx = idx

  return ok(bestIdx)

type KadDHTConfig* = ref object
  validator*: EntryValidator
  selector*: EntrySelector
  timeout*: chronos.Duration
  retries*: int
  replication*: int
  alpha*: int
  ttl*: chronos.Duration
  quorum*: int

proc new*(
    T: typedesc[KadDHTConfig],
    validator: EntryValidator = DefaultEntryValidator(),
    selector: EntrySelector = DefaultEntrySelector(),
    timeout: chronos.Duration = DefaultTimeout,
    retries: int = DefaultRetries,
    replication: int = DefaultReplication,
    alpha: int = DefaultAlpha,
    ttl: chronos.Duration = DefaultTTL,
    quorum: int = DefaultQuorum,
): T {.raises: [].} =
  KadDHTConfig(
    validator: validator,
    selector: selector,
    timeout: timeout,
    retries: retries,
    replication: replication,
    alpha: alpha,
    ttl: ttl,
    quorum: quorum,
  )

type KadDHT* = ref object of LPProtocol
  switch*: Switch
  rng*: ref HmacDrbgContext
  rtable*: RoutingTable
  maintenanceLoop*: Future[void]
  dataTable*: LocalTable
  config*: KadDHTConfig

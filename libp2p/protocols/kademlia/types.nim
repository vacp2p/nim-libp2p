# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sequtils, sets, heapqueue]
from std/times import format, now, parse, toTime, toUnix, utc
import chronos, chronicles, results, sugar, stew/arrayOps, nimcrypto/sha2
import ../../[peerid, switch, multihash, cid, multicodec, peeraddrpolicy]
import ../protocol
import ./protobuf

const
  IdLength* = 32 # 256-bit IDs

  DefaultMaxBuckets* = 256
  DefaultTimeout* = 5.seconds
  DefaultBucketRefreshTime* = 10.minutes
  DefaultBucketStaleTime* = 30.minutes
    # peer not seen for this duration marks bucket stale
  DefaultRetries* = 5
  DefaultReplication* = 20 ## aka `k` in the spec
  DefaultAlpha* = 10 # concurrency parameter
  DefaultQuorum* = 5 # number of GetValue responses needed to decide
  DefaultProviderRecordCapacity* = 500
    # maximum number of provider records to store at once
  DefaultProvidedKeyCapacity* = 500 # maximum number of provided keys to store at once
  DefaultRepublishInterval* = 10.minutes # same as bootstrap
  DefaultCleanupProvidersInterval* = 10.minutes # same as bootstrap
  DefaultProviderExpirationInterval* = 30.minutes # recommended by the spec
  DefaultRecordExpirationInterval* = 24.hours
    # KV entries older than this are considered stale and will be evicted
  DefaultCleanupDataEntriesInterval* = 1.hours # how often to scan for stale KV entries

  MaxMsgSize* = 4096

  DefaultMaxProvidersPerKey* = 20 ## upper bound on providers stored per key
  DefaultMaxShortlistSize* = DefaultReplication * 2
    ## upper bound on iterative-lookup shortlist
  DefaultMaxReceivedSize* = DefaultReplication
    ## upper bound on per-query ``ReceivedTable``
  DefaultMaxValueSize* = 3072
    ## upper bound (bytes) on a stored record value. Held below ``MaxMsgSize``
    ## (4096) to leave headroom for the protobuf overhead from other message
    ## fields, so an accepted value still fits in a single LP frame.
  DefaultMaxLocalRecords* = 500 ## upper bound on locally stored value records
  DefaultMaxConcurrentRpcs* = 100
    ## upper bound on in-flight outbound RPCs across find/get/put/provider
  DefaultMaxPeersPerIp* = 4
    ## upper bound on Kademlia routing-table peers sharing one exact IP
  DefaultMaxPeersPerSubnet* = 10
    ## upper bound on Kademlia routing-table peers sharing one IP subnet

type Key* = seq[byte]

proc toCid*(k: Key): Cid =
  let cidRes = Cid.init(k)
  if cidRes.isOk:
    cidRes.get()
  else:
    debug "Key is an invalid CID, encapsulating", key = k
    Cid.init(CIDv1, multiCodec("dag-pb"), MultiHash.digest("sha2-256", k).get()).get()

proc toKey*(mh: MultiHash): Key =
  mh.data.buffer

proc toKey*(c: Cid): Key =
  c.mhash().get().toKey()

proc toKey*(p: PeerId): Key =
  MultiHash.init(p.data).get().toKey()

proc toPeerId*(k: Key): Result[PeerId, string] =
  PeerId.init(k).mapErr(x => $x)

proc toPeer*(k: Key, switch: Switch): Result[Peer, string] =
  let peer = ?k.toPeerId()
  let addrs = switch.peerStore[AddressBook][peer]
  if addrs.len == 0:
    return err("Could not find peer addresses in address book")

  ok(
    Peer(
      id: Opt.some(peer.getBytes()),
      addrs: Opt.some(addrs),
      connection: Opt.none(ConnectionStatus),
    )
  )

proc toPeer*(peerInfo: PeerInfo): Peer =
  Peer(
    id: Opt.some(peerInfo.peerId.getBytes()),
    addrs: Opt.some(peerInfo.addrs),
    connection: Opt.none(ConnectionStatus),
  )

proc toPeers*(switch: Switch, keys: seq[Key]): seq[Peer] =
  var peers: seq[Peer]

  for p in keys:
    p.toPeer(switch).withValue(peer):
      peers.add(peer)

  return peers

proc toPeerIds*(peers: seq[Peer]): seq[PeerId] =
  var peerIds: seq[PeerId]

  for p in peers:
    let raw = p.id.valueOr:
      continue
    let pid = PeerId.init(raw).valueOr:
      continue
    peerIds.add(pid)

  return peerIds

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

proc hashFor*(k: Key, hasher: Opt[XorDHasher]): seq[byte] =
  return @(hasher.get(defaultHasher)(k))

proc xorDistance*(a, b: Key): XorDistance =
  doAssert a.len == IdLength and b.len == IdLength,
    "both keys must be " & $IdLength & " bytes"

  var response: XorDistance
  for i in 0 ..< a.len:
    response[i] = a[i] xor b[i]
  return response

proc xorDistance*(a, b: Key, hasher: Opt[XorDHasher]): XorDistance =
  xorDistance(a.hashFor(hasher), b.hashFor(hasher))

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
    selfIdPreHashed*: bool

  RoutingTable* = ref object
    selfId*: Key
    localNodeId*: Key
    buckets*: seq[Bucket]
    config*: RoutingTableConfig

  Provider* = Peer

  ProviderRecord* = object
    provider*: Provider
    expiresAt*: chronos.Moment
    key*: Key

  ProviderRecords* = ref object
    records*: HeapQueue[ProviderRecord]
    capacity*: int

  ProvidedKeys* = ref object
    provided*: Table[Key, chronos.Moment]
    capacity*: int

  ProviderManager* = ref object
    providerRecords*: ProviderRecords
    providedKeys*: ProvidedKeys
    knownKeys*: Table[Key, HashSet[Provider]]

proc new*(
    T: typedesc[ProviderManager], providerRecordCapacity: int, providedKeyCapacity: int
): T =
  let pm = T()

  pm.providerRecords = ProviderRecords(capacity: providerRecordCapacity)
  pm.providedKeys = ProvidedKeys(capacity: providedKeyCapacity)

  return pm

proc toPeerIds*(entries: seq[NodeEntry]): seq[PeerId] =
  var peerIds = newSeqOfCap[PeerId](entries.len)
  for e in entries:
    let peerId = e.nodeId.toPeerId().valueOr:
      error "cannot convert key to peer id", error
      continue
    peerIds.add(peerId)
  return peerIds

## Currently a string, because for some reason, that's what is chosen at the protobuf level
## TODO: convert between RFC3339 strings and use of integers (i.e. the _correct_ way)
type Timestamp* = string

const TimestampFormat* = "yyyy-MM-dd'T'HH:mm:ss'Z'"

proc now*(T: typedesc[Timestamp]): Timestamp {.gcsafe, raises: [].} =
  T(now().utc.format(TimestampFormat))

proc toUnixSeconds*(
    time: Timestamp
): Result[int64, ref CatchableError] {.gcsafe, raises: [].} =
  catch:
    parse(time, TimestampFormat, utc()).toTime().toUnix()

proc nowUnixSeconds*(): int64 {.gcsafe, raises: [].} =
  now().utc.toTime().toUnix()

type EntryRecord* = object
  value*: seq[byte]
  time*: Timestamp

proc init*(
    T: typedesc[EntryRecord], value: Key, time: Opt[Timestamp]
): EntryRecord {.gcsafe, raises: [].} =
  EntryRecord(value: value, time: time.get(Timestamp.now()))

type
  ReceivedTable* = TableRef[PeerId, Opt[EntryRecord]]
  CandidatePeers* = ref HashSet[PeerId]
  LocalTable* = Table[Key, EntryRecord]

proc insert*(
    self: var LocalTable, key: Key, value: sink seq[byte], time: Timestamp
) {.raises: [].} =
  debug "Local table insertion", key = key, value = value
  self[key] = EntryRecord(value: value, time: time)

proc get*(self: LocalTable, key: Key): Opt[EntryRecord] {.raises: [].} =
  if not self.hasKey(key):
    return Opt.none(EntryRecord)
  try:
    return Opt.some(self[key])
  except KeyError:
    raiseAssert "checked with hasKey"

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

type KadDHTLimits* = object
  maxProvidersPerKey*: Opt[int]
    ## Maximum number of distinct providers stored per key.
    ## ``Opt.none`` means unlimited; when limits are derived by the
    ## ``KadDHTConfig`` constructor this defaults to ``replication``.
  maxShortlistSize*: int
    ## Maximum number of peers retained in an iterative-lookup shortlist.
    ## When exceeded, farther peers are dropped so the shortlist stays bounded.
  maxReceivedSize*: int
    ## Maximum number of per-peer entries retained in a GET_VALUE
    ## ``ReceivedTable``.
  maxValueSize*: int
    ## Maximum size (bytes) of an individual record value. Enforced on
    ## ``putValue`` and on incoming PUT_VALUE / GET_VALUE records.
  maxLocalRecords*: Opt[int]
    ## Maximum number of records retained in the local value store.
    ## ``Opt.none`` means unlimited; when limits are derived by the
    ## ``KadDHTConfig`` constructor this defaults to ``DefaultMaxLocalRecords``.
  maxConcurrentRpcs*: int
    ## Maximum number of in-flight outbound RPCs (find/get/put/provider)
    ## across the whole node. Excess calls wait on a shared semaphore.
  maxPeersPerIp*: int
    ## Maximum number of Kademlia routing-table peers sharing one exact IP.
  maxPeersPerIpv4Subnet*: int
    ## Maximum number of Kademlia routing-table peers sharing one IPv4 /24.
  maxPeersPerIpv6Subnet*: int
    ## Maximum number of Kademlia routing-table peers sharing one IPv6 /64.

proc new*(T: typedesc[KadDHTLimits], replication: int, quorum: int): T {.raises: [].} =
  ## Builds a limits object whose shortlist/received caps and providers-per-key
  ## are sized off the actual ``replication`` and ``quorum`` so the configuration
  ## stays internally consistent (e.g. ``maxShortlistSize >= replication``,
  ## ``maxReceivedSize >= quorum``).
  T(
    maxProvidersPerKey: Opt.some(replication),
    maxShortlistSize: replication * 2,
    maxReceivedSize: max(replication, quorum),
    maxValueSize: DefaultMaxValueSize,
    maxLocalRecords: Opt.some(DefaultMaxLocalRecords),
    maxConcurrentRpcs: DefaultMaxConcurrentRpcs,
    maxPeersPerIp: DefaultMaxPeersPerIp,
    maxPeersPerIpv4Subnet: DefaultMaxPeersPerSubnet,
    maxPeersPerIpv6Subnet: DefaultMaxPeersPerSubnet,
  )

type KadDHTConfig* = object
  validator*: EntryValidator
  selector*: EntrySelector
  timeout*: chronos.Duration
  bucketRefreshTime*: chronos.Duration
  retries*: int
  replication*: int
  alpha*: int
  ttl*: chronos.Duration
  quorum*: int
  providerRecordCapacity*: int
  providedKeyCapacity*: int
  republishProvidedKeysInterval*: chronos.Duration
  cleanupProvidersInterval*: chronos.Duration
  providerExpirationInterval*: chronos.Duration
  recordExpirationInterval*: chronos.Duration
  cleanupDataEntriesInterval*: chronos.Duration
  addressPolicy*: PeerAddressPolicy
  hideConnectionStatus*: bool
  disableBootstrapping*: bool
  providerRejection*: bool
    ## When true, ADD_PROVIDER receivers reply with accepted/rejected on
    ## field 11; the sender spills over to farther peers when a full batch is
    ## rejected. The per-key cap (``limits.maxProvidersPerKey``) is always
    ## enforced regardless of this flag — this only controls whether
    ## rejections are acknowledged on the wire.
  limits*: KadDHTLimits

proc new*(
    K: typedesc[KadDHTConfig],
    validator: EntryValidator = DefaultEntryValidator(),
    selector: EntrySelector = DefaultEntrySelector(),
    timeout: chronos.Duration = DefaultTimeout,
    bucketRefreshTime: chronos.Duration = DefaultBucketRefreshTime,
    retries: int = DefaultRetries,
    replication: int = DefaultReplication,
    alpha: int = DefaultAlpha,
    quorum: int = DefaultQuorum,
    providerRecordCapacity = DefaultProviderRecordCapacity,
    providedKeyCapacity = DefaultProvidedKeyCapacity,
    republishProvidedKeysInterval: chronos.Duration = DefaultRepublishInterval,
    cleanupProvidersInterval: chronos.Duration = DefaultCleanupProvidersInterval,
    providerExpirationInterval: chronos.Duration = DefaultProviderExpirationInterval,
    recordExpirationInterval: chronos.Duration = DefaultRecordExpirationInterval,
    cleanupDataEntriesInterval: chronos.Duration = DefaultCleanupDataEntriesInterval,
    addressPolicy: PeerAddressPolicy = defaultAddressPolicy,
    hideConnectionStatus: bool = true,
    disableBootstrapping: bool = false,
    providerRejection: bool = false,
    limits: Opt[KadDHTLimits] = Opt.none(KadDHTLimits),
): K {.raises: [].} =
  let actualLimits = limits.valueOr:
    KadDHTLimits.new(replication, quorum)
  doAssert actualLimits.maxProvidersPerKey.isNone or
    actualLimits.maxProvidersPerKey.get() > 0,
    "maxProvidersPerKey must be > 0; use Opt.none(int) for unlimited"
  doAssert actualLimits.maxShortlistSize > 0, "maxShortlistSize must be > 0"
  doAssert actualLimits.maxReceivedSize > 0, "maxReceivedSize must be > 0"
  doAssert actualLimits.maxValueSize > 0, "maxValueSize must be > 0"
  doAssert actualLimits.maxLocalRecords.isNone or actualLimits.maxLocalRecords.get() > 0,
    "maxLocalRecords must be > 0; use Opt.none(int) for unlimited"
  doAssert actualLimits.maxConcurrentRpcs > 0, "maxConcurrentRpcs must be > 0"
  doAssert actualLimits.maxPeersPerIp > 0, "maxPeersPerIp must be > 0"
  doAssert actualLimits.maxPeersPerIpv4Subnet > 0, "maxPeersPerIpv4Subnet must be > 0"
  doAssert actualLimits.maxPeersPerIpv6Subnet > 0, "maxPeersPerIpv6Subnet must be > 0"
  doAssert actualLimits.maxShortlistSize >= replication,
    "maxShortlistSize must be >= replication so the shortlist can hold the target k-bucket"
  doAssert actualLimits.maxReceivedSize >= quorum,
    "maxReceivedSize must be >= quorum so getValue can ever satisfy quorum"
  KadDHTConfig(
    validator: validator,
    selector: selector,
    timeout: timeout,
    bucketRefreshTime: bucketRefreshTime,
    retries: retries,
    replication: replication,
    alpha: alpha,
    quorum: quorum,
    providerRecordCapacity: providerRecordCapacity,
    providedKeyCapacity: providedKeyCapacity,
    republishProvidedKeysInterval: republishProvidedKeysInterval,
    cleanupProvidersInterval: cleanupProvidersInterval,
    providerExpirationInterval: providerExpirationInterval,
    recordExpirationInterval: recordExpirationInterval,
    cleanupDataEntriesInterval: cleanupDataEntriesInterval,
    addressPolicy: addressPolicy,
    hideConnectionStatus: hideConnectionStatus,
    disableBootstrapping: disableBootstrapping,
    providerRejection: providerRejection,
    limits: actualLimits,
  )

type KadDHT* = ref object of LPProtocol
  switch*: Switch
  rng*: Rng
  rtable*: RoutingTable
  maintenanceLoop*: Future[void]
  republishLoop*: Future[void]
  expiredLoop*: Future[void]
  recordExpirationLoop*: Future[void]
  dataTable*: LocalTable
  providerManager*: ProviderManager
  config*: KadDHTConfig
  rpcSem*: AsyncSemaphore
    ## Bounds in-flight outbound RPCs to ``config.limits.maxConcurrentRpcs``.

template withRpcSlot*(kad: KadDHT) =
  ## Acquire one ``rpcSem`` slot until the enclosing scope exits. The slot is
  ## released whether the scope exits normally, raises, or is cancelled.
  await kad.rpcSem.acquire()
  defer:
    try:
      kad.rpcSem.release()
    except AsyncSemaphoreError:
      raiseAssert "rpcSem released without acquire"

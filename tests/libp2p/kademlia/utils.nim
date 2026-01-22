# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.
{.used.}

import algorithm, chronos, chronicles, results, sequtils, sets
import ../../../libp2p/[protocols/kademlia, switch, builders]
import ../../tools/[crypto, unittest]
import ./mock_kademlia

trace "chronicles has to be imported to fix Error: undeclared identifier: 'activeChroniclesStream'"

type PermissiveValidator* = ref object of EntryValidator
method isValid*(self: PermissiveValidator, key: Key, record: EntryRecord): bool =
  true

type RestrictiveValidator* = ref object of EntryValidator
method isValid(self: RestrictiveValidator, key: Key, record: EntryRecord): bool =
  false

type CandSelector* = ref object of EntrySelector
method select*(
    self: CandSelector, key: Key, values: seq[EntryRecord]
): Result[int, string] =
  return ok(0)

type OthersSelector* = ref object of EntrySelector
method select*(
    self: OthersSelector, key: Key, values: seq[EntryRecord]
): Result[int, string] =
  if values.len == 0:
    return err("no values were given")
  if values.len == 1:
    return ok(0)
  ok(1)

proc createSwitch*(): Switch =
  SwitchBuilder
  .new()
  .withRng(newRng())
  .withAddresses(@[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()])
  .withTcpTransport()
  .withMplex()
  .withNoise()
  .build()

proc countBucketEntries*(buckets: seq[Bucket], key: Key): uint32 =
  var res: uint32 = 0
  for b in buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        res += 1
  return res

proc containsData*(kad: KadDHT, key: Key, value: seq[byte]): bool =
  let record = kad.dataTable.get(key).valueOr:
    checkpoint("containsData: key not found: " & $key.shortLog())
    return false

  if record.value != value:
    checkpoint(
      "containsData: value mismatch for " & $key.shortLog() & " - expected: " & $value &
        ", got: " & $record.value
    )
    return false

  true

proc containsNoData*(kad: KadDHT, key: Key): bool =
  kad.dataTable.get(key).isNone()

proc setupMockKadSwitch*(
    validator: EntryValidator,
    selector: EntrySelector,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    cleanupProvidersInterval: Duration = chronos.milliseconds(100),
    republishProvidedKeysInterval: Duration = chronos.milliseconds(50),
    mismatchedRecordKey: Opt[Key] = Opt.none(Key),
    handleAddProviderMessage: Opt[Message] = Opt.none(Message),
): Future[(Switch, MockKadDHT)] {.async.} =
  let switch = createSwitch()
  let kad = MockKadDHT.new(
    switch,
    bootstrapNodes,
    config = KadDHTConfig.new(
      validator,
      selector,
      timeout = chronos.seconds(1),
      cleanupProvidersInterval = cleanupProvidersInterval,
      providerExpirationInterval = chronos.seconds(1),
      republishProvidedKeysInterval = republishProvidedKeysInterval,
    ),
  )
  kad.mismatchedRecordKey = mismatchedRecordKey
  kad.handleAddProviderMessage = handleAddProviderMessage

  switch.mount(kad)
  await switch.start()
  (switch, kad)

proc setupKadSwitch*(
    validator: EntryValidator,
    selector: EntrySelector,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    cleanupProvidersInterval: Duration = chronos.milliseconds(100),
    republishProvidedKeysInterval: Duration = chronos.milliseconds(50),
    replication: int = DefaultReplication,
): Future[(Switch, KadDHT)] {.async.} =
  let switch = createSwitch()
  let kad = KadDHT.new(
    switch,
    bootstrapNodes,
    config = KadDHTConfig.new(
      validator,
      selector,
      timeout = chronos.seconds(1),
      cleanupProvidersInterval = cleanupProvidersInterval,
      providerExpirationInterval = chronos.seconds(1),
      republishProvidedKeysInterval = republishProvidedKeysInterval,
      replication = replication,
    ),
  )

  switch.mount(kad)
  await switch.start()
  (switch, kad)

proc setupKadSwitches*(
    count: int,
    validator: EntryValidator = PermissiveValidator(),
    selector: EntrySelector = CandSelector(),
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    cleanupProvidersInterval: Duration = chronos.milliseconds(100),
    republishProvidedKeysInterval: Duration = chronos.milliseconds(50),
    replication: int = DefaultReplication,
): Future[seq[KadDHT]] {.async.} =
  var kads: seq[KadDHT]
  for i in 0 ..< count:
    var (_, kad) = await setupKadSwitch(
      validator, selector, bootstrapNodes, cleanupProvidersInterval,
      republishProvidedKeysInterval, replication,
    )
    kads.add(kad)
  kads

proc stopNodes*(nodes: seq[KadDHT]) {.async.} =
  await allFutures(nodes.mapIt(it.stop()))
  await allFutures(nodes.mapIt(it.switch.stop()))

proc connectNodes*(kad1, kad2: KadDHT) =
  ## Bidirectionally connect two KadDHT instances.
  # Add to routing tables
  discard kad1.rtable.insert(kad2.switch.peerInfo.peerId)
  discard kad2.rtable.insert(kad1.switch.peerInfo.peerId)

  # Store addresses so nodes can dial each other
  kad1.switch.peerStore[AddressBook][kad2.switch.peerInfo.peerId] =
    kad2.switch.peerInfo.addrs
  kad2.switch.peerStore[AddressBook][kad1.switch.peerInfo.peerId] =
    kad1.switch.peerInfo.addrs

proc connectNodesStar*(nodes: seq[KadDHT]) =
  ## Star: 1-2; 1-3; 2-1; 2-3, 3-1, 3-2
  ## 
  for dialer in nodes:
    for listener in nodes:
      if dialer.switch.peerInfo.peerId != listener.switch.peerInfo.peerId:
        connectNodes(dialer, listener)

proc hasKey*(kad: KadDHT, key: Key): bool =
  for b in kad.rtable.buckets:
    for ent in b.peers:
      if ent.nodeId == key:
        return true
  return false

proc hasKeys*(kad: KadDHT, keys: seq[Key]): bool =
  keys.allIt(kad.hasKey(it))

proc hasNoKeys*(kad: KadDHT, keys: seq[Key]): bool =
  keys.allIt(not kad.hasKey(it))

proc pluckPeerIds*(kads: seq[KadDHT]): seq[PeerId] =
  kads.mapIt(it.switch.peerInfo.peerId)

proc containsPeer*(providers: HashSet[Peer], node: KadDHT): bool =
  let providerIds = providers.toSeq().mapIt(it.id)
  node.switch.peerInfo.peerId.getBytes() in providerIds

proc toPeer*(node: KadDHT): Peer =
  node.switch.peerInfo.toPeer()

proc randomPeerId*(): PeerId =
  PeerId.random(rng()).get()

proc populateRoutingTable*(kad: KadDHT, count: int) =
  for i in 0 ..< count:
    discard kad.rtable.insert(randomPeerId())

proc getPeersFromRoutingTable*(kad: KadDHT): seq[PeerId] =
  var peersInTable: seq[PeerId]
  for bucket in kad.rtable.buckets:
    for entry in bucket.peers:
      peersInTable.add(entry.nodeId.toPeerId().get())
  peersInTable

proc nonEmptyBuckets*(kad: KadDHT): seq[int] =
  var bucketIndices: seq[int]
  for i, bucket in kad.rtable.buckets:
    if bucket.peers.len > 0:
      bucketIndices.add(i)
  bucketIndices

proc makeBucketStale*(bucket: var Bucket) =
  for peer in bucket.peers.mitems:
    peer.lastSeen = Moment.now() - (DefaultBucketStaleTime + 1.minutes)

proc sortPeers*(
    peers: seq[PeerId], targetKey: Key, hasher: Opt[XorDHasher]
): seq[PeerId] =
  peers
  .mapIt((it, xorDistance(it, targetKey, hasher)))
  .sorted(
    proc(a, b: auto): int =
      cmp(a[1], b[1])
  )
  .mapIt(it[0])

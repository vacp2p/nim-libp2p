# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[sequtils, tables, sets, heapqueue]
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid]
import ../../utils/heartbeat
import ../protocol
import ./[protobuf, types, find]

proc `==`*(a, b: ProviderRecord): bool {.inline.} =
  a.provider.id == b.provider.id and a.key == b.key

# for HeapQueue
proc `<`*(a, b: ProviderRecord): bool {.inline.} =
  a.expiresAt < b.expiresAt

proc `<`*(a: ProviderRecord, b: chronos.Moment): bool {.inline.} =
  a.expiresAt < b

proc deleteOldest(pk: ProvidedKeys) =
  ## Delete oldest provided key from ProvidedKeys
  var oldest: Cid
  var oldestMoment = chronos.Moment.now()
  for key, moment in pk.provided:
    if oldestMoment > moment:
      oldest = key
      oldestMoment = moment
  pk.provided.del(oldest)

proc isFull*(pk: ProvidedKeys): bool {.inline.} =
  pk.provided.len() >= pk.capacity

proc len*(pk: ProvidedKeys): int {.inline.} =
  pk.provided.len()

proc hasKey*(pk: ProvidedKeys, c: Cid): bool {.inline.} =
  pk.provided.hasKey(c)

proc del*(pk: ProvidedKeys, c: Cid) {.inline.} =
  pk.provided.del(c)

proc pop*(pr: ProviderRecords): ProviderRecord {.inline.} =
  pr.records.pop()

proc len*(pr: ProviderRecords): int {.inline.} =
  pr.records.len()

proc del*(pr: ProviderRecords, index: Natural) {.inline.} =
  pr.records.del(index)

proc find*(pr: ProviderRecords, record: ProviderRecord): int {.inline.} =
  pr.records.find(record)

proc push*(pr: ProviderRecords, record: ProviderRecord) {.inline.} =
  pr.records.push(record)

proc isFull*(pr: ProviderRecords): bool {.inline.} =
  pr.records.len() >= pr.capacity

proc `[]`*(pr: ProviderRecords, i: int): ProviderRecord {.inline.} =
  pr.records[i]

proc removeProviderRecord(pm: ProviderManager, record: ProviderRecord) =
  ## Remove provider record and related keys

  let recordIdx = pm.providerRecords.find(record)
  if recordIdx != -1:
    pm.providerRecords.del(recordIdx)

  try:
    pm.knownKeys[record.key].excl(record.provider)
    if pm.knownKeys[record.key].len() == 0:
      pm.knownKeys.del(record.key)
  except KeyError:
    return

proc addProviderRecord(pm: ProviderManager, record: ProviderRecord) =
  # remove previous providerRecord if any
  pm.removeProviderRecord(record)

  if pm.providerRecords.isFull():
    let oldest = pm.providerRecords.pop()
    pm.removeProviderRecord(oldest)

  if not pm.knownKeys.hasKey(record.key):
    pm.knownKeys[record.key] = initHashSet[Provider]()

  try:
    pm.knownKeys[record.key].incl(record.provider)

    pm.providerRecords.push(record)
  except KeyError:
    raiseAssert("checked with hasKey")

proc dispatchAddProvider(
    switch: Switch, peer: PeerId, cid: Cid
) {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let conn = await switch.dial(peer, KadCodec)
  defer:
    await conn.close()

  let msg = Message(
    msgType: MessageType.addProvider,
    key: cid.toKey(),
    providerPeers: @[switch.peerInfo.toPeer()],
  )
  await conn.writeLp(msg.encode().buffer)

proc addProvider*(kad: KadDHT, cid: Cid) {.async: (raises: [CancelledError]), gcsafe.} =
  ## Find the closest nodes to the key via FIND_NODE and send ADD_PROVIDER with self's peerInfo to each of them

  let peers = await kad.findNode(cid.toKey())
  for chunk in peers.toChunks(kad.config.alpha):
    let rpcBatch = chunk.mapIt(kad.switch.dispatchAddProvider(it, cid))
    try:
      await rpcBatch.allFutures().wait(kad.config.timeout)
    except AsyncTimeoutError:
      # Dispatch will timeout if any of the calls don't receive a response (which is normal)
      discard

proc startProviding*(kad: KadDHT, c: Cid) {.async: (raises: [CancelledError]).} =
  if kad.providerManager.providedKeys.isFull():
    kad.providerManager.providedKeys.deleteOldest()

  kad.providerManager.providedKeys.provided[c] = chronos.Moment.now()
  await kad.addProvider(c)

proc stopProviding*(kad: KadDHT, c: Cid) =
  kad.providerManager.providedKeys.del(c)

proc manageRepublishProvidedKeys*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "republish provided keys", kad.config.republishProvidedKeysInterval:
    let providedKeys = kad.providerManager.providedKeys.provided
    for c in providedKeys.keys():
      await kad.addProvider(c)

proc anyExpired(pr: ProviderRecords): bool =
  pr.len() > 0 and pr.records[0] < chronos.Moment.now()

proc manageExpiredProviders*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "cleanup expired provider records", kad.config.cleanupProvidersInterval:
    while kad.providerManager.providerRecords.anyExpired():
      let expired = kad.providerManager.providerRecords.pop()
      kad.providerManager.removeProviderRecord(expired)

proc handleAddProvider*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  if Cid.init(msg.key).isErr():
    error "Received key is an invalid CID", msg = msg, conn = conn, key = msg.key
    return

  # filter out infos that do not match sender's
  let peerBytes = conn.peerId.getBytes()

  for peer in msg.providerPeers.filterIt(it.id == peerBytes):
    if not PeerId.init(peer.id).isOk():
      continue

    # add provider to providerManager
    kad.providerManager.addProviderRecord(
      ProviderRecord(
        provider: peer,
        expiresAt: chronos.Moment.now() + kad.config.providerExpirationInterval,
        key: msg.key.toCid(),
      )
    )

proc dispatchGetProviders(
    switch: Switch, peer: PeerId, key: Key
): Future[(HashSet[Provider], seq[Peer])] {.
    async: (raises: [CancelledError, DialFailedError, LPStreamError])
.} =
  let conn = await switch.dial(peer, KadCodec)
  defer:
    await conn.close()
  let msg = Message(msgType: MessageType.getProviders, key: key)
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).valueOr:
    error "GetProviders reply decode fail", error = error, conn = conn
    return

  debug "Received reply for GetProviders", reply = reply

  var providers: HashSet[Provider]
  for peer in reply.providerPeers:
    let p = PeerId.init(peer.id).valueOr:
      debug "Invalid peer id received", peerId = peer.id, error = error
      continue
    providers.incl(peer)

  return (providers, reply.closerPeers)

proc nextCandidates(
    allCandidates: HashSet[PeerId], visitedCandidates: HashSet[PeerId], alpha: int
): seq[PeerId] =
  let unvisitedCandidates = allCandidates - visitedCandidates
  if unvisitedCandidates.len() == 0:
    return @[]

  return unvisitedCandidates.toSeq()[0 .. min(alpha, unvisitedCandidates.len() - 1)]

proc getProviders*(
    kad: KadDHT, key: Key
): Future[HashSet[Provider]] {.
    async: (raises: [LPStreamError, DialFailedError, CancelledError]), gcsafe
.} =
  ## Get providers for a given `key` from the nodes closest to that `key`.

  var
    allCandidates: HashSet[PeerId] = (await kad.findNode(key)).toHashSet()
    visitedCandidates: HashSet[PeerId]
    allProviders: HashSet[Provider]

  # run until we find at least K providers
  while allProviders.len() < kad.config.replication:
    let candidates = nextCandidates(allCandidates, visitedCandidates, kad.config.alpha)
    if candidates.len() == 0:
      break

    let rpcBatch = candidates.mapIt(kad.switch.dispatchGetProviders(it, key))
    for (providers, closerPeers) in await rpcBatch.collectCompleted(kad.config.timeout):
      allProviders.incl(providers)
      allCandidates.incl(closerPeers.toPeerIds().toHashSet())

    visitedCandidates.incl(candidates.toHashSet())

  return allProviders

proc handleGetProviders*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let cid = msg.key.toCid()

  var providers =
    kad.providerManager.knownKeys.getOrDefault(cid, initHashSet[Provider]())

  # check if we are providing the key as well
  if kad.providerManager.providedKeys.provided.hasKey(cid):
    providers.incl(kad.switch.peerInfo.toPeer())

  try:
    await conn.writeLp(
      Message(
        msgType: MessageType.getProviders,
        key: msg.key,
        closerPeers: kad.findClosestPeers(msg.key),
        providerPeers: providers.toSeq(),
      ).encode().buffer
    )
  except LPStreamError as exc:
    debug "Failed to send get-providers RPC reply", conn = conn, err = exc.msg

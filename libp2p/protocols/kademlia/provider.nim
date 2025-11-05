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

proc `==`*(a, b: ProviderRecord): bool =
  a.provider.id == b.provider.id and a.key == b.key

# for HeapQueue
proc `<`*(a, b: ProviderRecord): bool =
  a.expiresAt < b.expiresAt

proc `<`*(a: ProviderRecord, b: chronos.Moment): bool =
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

proc isFull*(pk: ProvidedKeys): bool =
  pk.provided.len() >= pk.capacity

proc len*(pk: ProvidedKeys): int =
  pk.provided.len()

proc hasKey*(pk: ProvidedKeys, c: Cid): bool =
  pk.provided.hasKey(c)

proc del*(pk: ProvidedKeys, c: Cid) =
  pk.provided.del(c)

proc pop*(pr: ProviderRecords): ProviderRecord =
  pr.records.pop()

proc len*(pr: ProviderRecords): int =
  pr.records.len()

proc del*(pr: ProviderRecords, index: Natural) =
  pr.records.del(index)

proc find*(pr: ProviderRecords, record: ProviderRecord): int =
  pr.records.find(record)

proc push*(pr: ProviderRecords, record: ProviderRecord) =
  pr.records.push(record)

proc isFull*(pr: ProviderRecords): bool =
  pr.records.len() >= pr.capacity

proc `[]`*(pr: ProviderRecords, i: int): ProviderRecord =
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

    # push new providerRecord
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
    let p = PeerId.init(peer.id).valueOr:
      continue

    # add provider to providerManager
    kad.providerManager.addProviderRecord(
      ProviderRecord(
        provider: peer,
        expiresAt: chronos.Moment.now() + kad.config.providerExpirationInterval,
        key: msg.key.toCid(),
      )
    )

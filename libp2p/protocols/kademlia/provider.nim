# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
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
  a.provider.id == b.provider.id and a.cid == b.cid

# for HeapQueue
proc `<`*(a, b: ProviderRecord): bool =
  a.expiresAt < b.expiresAt

proc `<`*(a: ProviderRecord, b: chronos.Moment): bool =
  a.expiresAt < b

proc addProviderRecord(pm: ProviderManager, record: ProviderRecord) =
  if not pm.knownCids.hasKey(record.cid):
    pm.knownCids[record.cid] = initHashSet[Provider]()

  try:
    pm.knownCids[record.cid].incl(record.provider)

    # remove old providerRecord if any
    let oldRecordIdx = pm.records.find(record)
    if oldRecordIdx != -1:
      pm.records.del(oldRecordIdx)

    # push new providerRecord
    pm.records.push(record)
  except KeyError:
    raiseAssert("checked with hasKey")

proc removeProviderRecord(pm: ProviderManager, record: ProviderRecord) =
  ## Remove provider record and related keys

  if not pm.knownCids.hasKey(record.cid):
    return

  try:
    pm.knownCids[record.cid].excl(record.provider)
    if pm.knownCids[record.cid].len() == 0:
      pm.knownCids.del(record.cid)
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

proc startProviding*(
    kad: KadDHT, c: Cid, duration: chronos.Duration = DefaultProvideInterval
) {.async: (raises: [CancelledError]).} =
  kad.providerManager.providedCids.add(c, chronos.Moment.now() + duration)
  await kad.addProvider(c)

proc stopProviding*(kad: KadDHT, c: Cid) =
  kad.providerManager.providedCids.del(c)

proc manageRepublishProvidedCids*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "republish provided cids", kad.config.republishProvidedKeysInterval:
    let providedCids = kad.providerManager.providedCids
    for cid, expiresAt in providedCids:
      if expiresAt <= chronos.Moment.now():
        kad.providerManager.providedCids.del(cid)
      else:
        await kad.addProvider(cid)

proc hasExpiredRecords(pm: ProviderManager): bool =
  pm.records.len() > 0 and pm.records[0] < chronos.Moment.now()

proc manageExpiredProviders*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "cleanup expired provider records", kad.config.cleanupProvidersInterval:
    while kad.providerManager.hasExpiredRecords():
      let expired = kad.providerManager.records.pop()
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
        cid: msg.key.toCid(),
      )
    )

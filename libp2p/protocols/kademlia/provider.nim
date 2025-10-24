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

# for HeapQueue
proc `<`*(a, b: ProviderRecord): bool =
  a.expiresAt < b.expiresAt

proc `<`*(a: ProviderRecord, b: chronos.Moment): bool =
  a.expiresAt < b

proc addProviderRecord(pm: ProviderManager, record: ProviderRecord) =
  if not pm.knownKeys.hasKey(record.key):
    pm.knownKeys[record.key] = initHashSet[Provider]()

  try:
    pm.knownKeys[record.key].incl(record.provider)
    pm.records.push(record) # TODO: handle duplicates
  except KeyError:
    raiseAssert("checked with hasKey")

proc rmProviderRecord(pm: ProviderManager, record: ProviderRecord) =
  ## Remove provider record and related keys

  if not pm.knownKeys.hasKey(record.key):
    return

  try:
    pm.knownKeys[record.key].excl(record.provider)
    if pm.knownKeys[record.key].len() == 0:
      pm.knownKeys.del(record.key)
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
  kad.providerManager.providedKeys.incl(c)
  await kad.addProvider(c)

proc stopProviding*(kad: KadDHT, c: Cid) =
  kad.providerManager.providedKeys.excl(c)

proc manageRepublishProvidedKeys*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "republish provided keys", kad.config.republishProvidedKeysInterval:
    for c in kad.providerManager.providedKeys:
      await kad.addProvider(c)

proc manageExpiredProviders*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  var records = kad.providerManager.records

  heartbeat "cleanup expired provider records", kad.config.cleanupProvidersInterval:
    while records.len() > 0 and records[0] < chronos.Moment.now():
      let expired = records.pop()
      kad.providerManager.rmProviderRecord(expired)

proc handleAddProvider*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let key = msg.key

  if Cid.init(key).isErr():
    error "Received key is an invalid CID", msg = msg, conn = conn, key = key
    return

  # filter out infos that do not match sender's
  let peerBytes = conn.peerId.getBytes()

  for peer in msg.providerPeers.filterIt(it.id == peerBytes):
    let p = PeerId.init(peer.id).valueOr:
      debug "Invalid peer id received", error = error
      continue

    # add provider to providerManager
    kad.providerManager.addProviderRecord(
      ProviderRecord(
        provider: peer,
        expiresAt: chronos.Moment.now() + kad.config.providerExpirationInterval,
        key: key.toCid(),
      )
    )

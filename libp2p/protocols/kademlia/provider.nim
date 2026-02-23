# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, tables, sets, heapqueue]
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid]
import ../../utils/heartbeat
import ../protocol
import ./[protobuf, types, find, kademlia_metrics]

logScope:
  topics = "kad-dht provider"

proc `==`*(a, b: ProviderRecord): bool {.inline.} =
  a.provider.id == b.provider.id and a.key == b.key

# for HeapQueue
proc `<`*(a, b: ProviderRecord): bool {.inline.} =
  a.expiresAt < b.expiresAt

proc `<`*(a: ProviderRecord, b: chronos.Moment): bool {.inline.} =
  a.expiresAt < b

proc deleteOldest(pk: ProvidedKeys) =
  ## Delete oldest provided key from ProvidedKeys
  var oldest: Key
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

proc hasKey*(pk: ProvidedKeys, k: Key): bool {.inline.} =
  pk.provided.hasKey(k)

proc del*(pk: ProvidedKeys, k: Key) {.inline.} =
  pk.provided.del(k)

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
    switch: Switch, peer: PeerId, key: Key, codec: string
) {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let conn = await switch.dial(peer, switch.peerStore[AddressBook][peer], codec)
  defer:
    await conn.close()

  let msg = Message(
    msgType: MessageType.addProvider,
    key: key,
    providerPeers: @[switch.peerInfo.toPeer()],
  )
  let encoded = msg.encode()
  kad_messages_sent.inc(labelValues = [$MessageType.addProvider])
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.addProvider]
  )
  await conn.writeLp(encoded.buffer)

proc addProvider*(kad: KadDHT, key: Key) {.async: (raises: [CancelledError]), gcsafe.} =
  ## Find the closest nodes to the key via FIND_NODE and send ADD_PROVIDER with self's peerInfo to each of them

  let peers = await kad.findNode(key)
  for chunk in peers.toChunks(kad.config.alpha):
    let rpcBatch = chunk.mapIt(kad.switch.dispatchAddProvider(it, key, kad.codec))
    try:
      await rpcBatch.allFutures().wait(kad.config.timeout)
    except AsyncTimeoutError:
      # Dispatch will timeout if any of the calls don't receive a response (which is normal)
      discard

proc addProvider*(kad: KadDHT, cid: Cid) {.async: (raises: [CancelledError]), gcsafe.} =
  await addProvider(kad, cid.toKey())

proc startProviding*(kad: KadDHT, c: Cid) {.async: (raises: [CancelledError]).} =
  if kad.providerManager.providedKeys.isFull():
    kad.providerManager.providedKeys.deleteOldest()

  let k = c.toKey()
  kad.providerManager.providedKeys.provided[k] = chronos.Moment.now()
  await kad.addProvider(k)

proc stopProviding*(kad: KadDHT, c: Cid) =
  kad.providerManager.providedKeys.del(c.toKey())

proc manageRepublishProvidedKeys*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "republish provided keys", kad.config.republishProvidedKeysInterval:
    let providedKeys = kad.providerManager.providedKeys.provided
    for k in providedKeys.keys():
      await kad.addProvider(k)

proc anyExpired(pr: ProviderRecords): bool =
  pr.len() > 0 and pr.records[0] < chronos.Moment.now()

proc manageExpiredProviders*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "cleanup expired provider records", kad.config.cleanupProvidersInterval:
    while kad.providerManager.providerRecords.anyExpired():
      let expired = kad.providerManager.providerRecords.pop()
      kad.providerManager.removeProviderRecord(expired)

method handleAddProvider*(
    kad: KadDHT, conn: Connection, msg: Message
) {.base, async: (raises: [CancelledError]).} =
  if not MultiHash.validate(msg.key):
    error "Received key is an invalid Multihash", msg = msg, conn = conn, key = msg.key
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
        key: msg.key,
      )
    )

proc dispatchGetProviders*(
    kad: KadDHT, peer: PeerId, key: Key
): Future[Opt[Message]] {.
    async: (raises: [CancelledError, DialFailedError, LPStreamError]), gcsafe
.} =
  let conn =
    await kad.switch.dial(peer, kad.switch.peerStore[AddressBook][peer], kad.codec)
  defer:
    await conn.close()
  let msg = Message(msgType: MessageType.getProviders, key: key)
  let encoded = msg.encode()

  kad_messages_sent.inc(labelValues = [$MessageType.getProviders])
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.getProviders]
  )

  var replyBuf: seq[byte]
  kad_message_duration_ms.time(labelValues = [$MessageType.getProviders]):
    await conn.writeLp(encoded.buffer)
    replyBuf = await conn.readLp(MaxMsgSize)

  kad_message_bytes_received.inc(
    replyBuf.len.int64, labelValues = [$MessageType.getProviders]
  )

  let reply = Message.decode(replyBuf).valueOr:
    error "GetProviders reply decode fail", error = error, conn = conn
    return Opt.none(Message)

  if reply.closerPeers.len > 0:
    kad_responses_with_closer_peers.inc(labelValues = [$MessageType.getProviders])

  debug "Received reply for GetProviders", peer = peer, reply = reply

  conn.observedAddr.withValue(observedAddr):
    kad.updatePeers(@[PeerInfo(peerId: conn.peerId, addrs: @[observedAddr])])

  return Opt.some(reply)

proc getProviders*(
    kad: KadDHT, key: Key
): Future[HashSet[Provider]] {.
    async: (raises: [LPStreamError, DialFailedError, CancelledError]), gcsafe
.} =
  ## Get providers for a given `key` from the nodes closest to that `key`.

  var allProviders: HashSet[Provider]

  # Include ourselves if we already provide the key
  if kad.providerManager.providedKeys.provided.hasKey(key):
    allProviders.incl(kad.switch.peerInfo.toPeer())

  let onReply = proc(
      peerId: PeerId, msgOpt: Opt[Message], state: var LookupState
  ): Future[void] {.async: (raises: []), gcsafe.} =
    let reply = msgOpt.valueOr:
      return

    for provider in reply.providerPeers:
      if not PeerId.init(provider.id).isOk():
        debug "Invalid peer id received", peerId = provider.id
        continue
      allProviders.incl(provider)

  let stop = proc(state: LookupState): bool {.gcsafe.} =
    allProviders.len() >= kad.config.replication

  discard await kad.iterativeLookup(key, dispatchGetProviders, onReply, stop)

  return allProviders

proc handleGetProviders*(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  var providers =
    kad.providerManager.knownKeys.getOrDefault(msg.key, initHashSet[Provider]())

  # check if we are providing the key as well
  if kad.providerManager.providedKeys.provided.hasKey(msg.key):
    providers.incl(kad.switch.peerInfo.toPeer())

  let response = Message(
    msgType: MessageType.getProviders,
    key: msg.key,
    closerPeers: kad.findClosestPeers(msg.key),
    providerPeers: providers.toSeq(),
  )
  let encoded = response.encode()
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.getProviders]
  )
  try:
    await conn.writeLp(encoded.buffer)
  except LPStreamError as exc:
    debug "Failed to send get-providers RPC reply", conn = conn, err = exc.msg

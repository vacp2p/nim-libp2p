# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## Provider record management for the Kademlia DHT.
## Receivers always enforce ``KadDHTConfig.limits.maxProvidersPerKey``; when
## ``providerRejection`` is true they additionally reply accepted/rejected on
## field 11 so senders can spill over to farther peers. Without
## ``providerRejection`` the limit is enforced silently — over-cap
## advertisements are dropped without a reply.
## Re-advertisements are always accepted.

import std/[sequtils, tables, sets, heapqueue]
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid]
import ../../utils/[heartbeat, future]
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

proc del*(pr: ProviderRecords, index: int) {.inline.} =
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
    kad: KadDHT, peer: PeerId, key: Key
): Future[Result[AddProviderStatus, string]] {.async: (raises: [CancelledError]).} =
  withRpcSlot(kad)
  let streamRes = catch:
    await kad.switch.dial(peer, kad.switch.peerStore[AddressBook][peer], kad.codec)
  if streamRes.isErr:
    return err(streamRes.error.msg)
  let stream = streamRes.value()
  defer:
    await stream.close()

  let msg = Message(
    msgType: MessageType.addProvider,
    key: key,
    providerPeers: @[kad.switch.peerInfo.toPeer()],
  )
  let encoded = msg.encode(kad.config.hideConnectionStatus)
  kad_messages_sent.inc(labelValues = [$MessageType.addProvider])
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.addProvider]
  )
  let writeRes = catch:
    await stream.writeLp(encoded.buffer)
  if writeRes.isErr:
    return err(writeRes.error.msg)

  if not kad.config.providerRejection:
    return ok(AddProviderStatus.accepted)

  let readFut = stream.readLp(MaxMsgSize)
  if not (await readFut.withTimeout(kad.config.timeout)):
    return ok(AddProviderStatus.accepted)
  let readRes = catch:
    await readFut
  if readRes.isErr:
    return ok(AddProviderStatus.accepted)

  let reply = Message.decode(readRes.value).valueOr:
    return ok(AddProviderStatus.accepted)

  return ok(reply.providerStatus.get(AddProviderStatus.accepted))

proc sendBatch(kad: KadDHT, peers: seq[PeerId], key: Key): auto =
  peers.mapIt(kad.dispatchAddProvider(it, key))

proc countResults[T](rpcBatch: seq[T]): (int, int) =
  var accepted, rejected: int
  for fut in rpcBatch:
    if not fut.finished():
      discard # batch timeout fired before request completed
    elif fut.failed():
      discard # transport/connection error
    elif not fut.value().isOk():
      discard # protocol/decode error
    else:
      case fut.value().value()
      of AddProviderStatus.accepted:
        accepted.inc()
      of AddProviderStatus.rejected:
        rejected.inc()
  (accepted, rejected)

proc addProviderSpillover(kad: KadDHT, key: Key) {.async: (raises: [CancelledError]).} =
  let allPeers = (
    await kad.iterativeLookup(key, findNodeDispatch, noopReply, closestAvailableStop)
  ).allSortedPeers()

  var stored = 0
  for chunk in allPeers.toChunks(kad.config.alpha):
    if stored >= kad.config.replication:
      break
    let batch = kad.sendBatch(chunk, key)
    # Batch timeout must exceed the per-peer reply timeout to account for dial
    # time. Each future waits up to `timeout` for a reply *after* the dial
    # completes, so the batch timeout must outlast that wait; otherwise
    # non-rejection peers (which default to accepted on reply timeout) may
    # still be mid-wait when countResults runs and get skipped, causing the
    # stored count to be too low and triggering unnecessary spillover rounds.
    await batch.allFuturesWaitOrTimeout(kad.config.timeout + kad.config.timeout div 4)
    let (accepted, rejected) = batch.countResults()
    stored += accepted
    if accepted == 0 and rejected == chunk.len:
      kad_provider_spillover_rounds.inc()
      debug "ADD_PROVIDER batch fully rejected, spilling over",
        key = key, batchSize = chunk.len

proc addProvider*(kad: KadDHT, key: Key) {.async: (raises: [CancelledError]), gcsafe.} =
  if kad.config.providerRejection:
    await kad.addProviderSpillover(key)
  else:
    let peers = await kad.findNode(key)
    for chunk in peers.toChunks(kad.config.alpha):
      await kad.sendBatch(chunk, key).allFuturesWaitOrTimeout(kad.config.timeout)

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

proc sendAddProviderResponse(
    stream: Stream, kad: KadDHT, status: AddProviderStatus
) {.async: (raises: [CancelledError]).} =
  let response =
    Message(msgType: MessageType.addProvider, providerStatus: Opt.some(status))
  try:
    await stream.writeLp(response.encode(kad.config.hideConnectionStatus).buffer)
  except LPStreamError as exc:
    debug "Failed to send add-provider response",
      stream = stream, err = exc.msg, status = status

method handleAddProvider*(
    kad: KadDHT, stream: Stream, msg: Message
) {.base, async: (raises: [CancelledError]).} =
  if not MultiHash.validate(msg.key):
    error "Received key is an invalid Multihash",
      msg = msg, stream = stream, key = msg.key
    if kad.config.providerRejection:
      await stream.sendAddProviderResponse(kad, AddProviderStatus.rejected)
    return

  # filter out infos that do not match sender's
  let peerBytes = stream.peerId.getBytes()
  let validPeers =
    msg.providerPeers.filterIt(it.id == peerBytes and PeerId.init(it.id).isOk())

  # Per-key cap is enforced regardless of providerRejection: when rejection is
  # disabled the receiver still drops over-cap providers, just silently.
  var atCap = false
  kad.config.limits.maxProvidersPerKey.withValue(limit):
    let existingProviders =
      kad.providerManager.knownKeys.getOrDefault(msg.key, initHashSet[Provider]())
    let senderIsKnown = existingProviders.anyIt(it.id == peerBytes)
    # Re-advertisements by the same provider are exempt: addProviderRecord
    # replaces the existing record so the set size doesn't grow.
    let effectiveCount = existingProviders.len - (if senderIsKnown: 1 else: 0)
    if effectiveCount >= limit:
      atCap = true
      debug "ADD_PROVIDER rejected: per-key limit reached", key = msg.key, limit = limit

  if not atCap:
    for peer in validPeers:
      kad.providerManager.addProviderRecord(
        ProviderRecord(
          provider: peer,
          expiresAt: chronos.Moment.now() + kad.config.providerExpirationInterval,
          key: msg.key,
        )
      )

  if kad.config.providerRejection:
    let status =
      if atCap or validPeers.len == 0:
        AddProviderStatus.rejected
      else:
        AddProviderStatus.accepted
    if status == AddProviderStatus.rejected:
      kad_provider_rejections_sent.inc()
    await stream.sendAddProviderResponse(kad, status)

proc dispatchGetProviders*(
    kad: KadDHT, peer: PeerId, key: Key
): Future[Result[Message, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  withRpcSlot(kad)
  let streamRes = catch:
    await kad.switch.dial(peer, kad.switch.peerStore[AddressBook][peer], kad.codec)
  if streamRes.isErr:
    return err(streamRes.error.msg)
  let stream = streamRes.value()
  defer:
    await stream.close()
  let msg = Message(msgType: MessageType.getProviders, key: key)
  let encoded = msg.encode(kad.config.hideConnectionStatus)

  kad_messages_sent.inc(labelValues = [$MessageType.getProviders])
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.getProviders]
  )

  var replyBuf: seq[byte]
  var ioRes: Result[void, ref CatchableError]
  kad_message_duration_ms.time(labelValues = [$MessageType.getProviders]):
    ioRes = catch:
      await stream.writeLp(encoded.buffer)
      replyBuf = await stream.readLp(MaxMsgSize)
  if ioRes.isErr:
    return err(ioRes.error.msg)

  kad_message_bytes_received.inc(
    replyBuf.len.int64, labelValues = [$MessageType.getProviders]
  )

  let reply = Message.decode(replyBuf).valueOr:
    return err("GetProviders reply decode fail")

  if reply.closerPeers.len > 0:
    kad_responses_with_closer_peers.inc(labelValues = [$MessageType.getProviders])

  debug "Received reply for GetProviders", peer = peer, reply = reply

  stream.observedAddr.withValue(observedAddr):
    kad.updatePeers(@[PeerInfo(peerId: stream.peerId, addrs: @[observedAddr])])

  return ok(reply)

proc getProviders*(
    kad: KadDHT, key: Key
): Future[HashSet[Provider]] {.
    async: (raises: [LPStreamError, CancelledError]), gcsafe
.} =
  ## Get providers for a given `key` from the nodes closest to that `key`.

  var allProviders: HashSet[Provider]

  # Include ourselves if we already provide the key
  if kad.providerManager.providedKeys.provided.hasKey(key):
    allProviders.incl(kad.switch.peerInfo.toPeer())

  let onReply = proc(
      peerId: PeerId, msgOpt: Opt[Message], state: LookupState
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
    kad: KadDHT, stream: Stream, msg: Message
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
  let encoded = response.encode(kad.config.hideConnectionStatus)
  kad_message_bytes_sent.inc(
    encoded.buffer.len.int64, labelValues = [$MessageType.getProviders]
  )
  try:
    await stream.writeLp(encoded.buffer)
  except LPStreamError as exc:
    debug "Failed to send get-providers RPC reply", stream = stream, err = exc.msg

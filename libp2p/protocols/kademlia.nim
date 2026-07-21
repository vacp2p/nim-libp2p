# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, results, sequtils
import ../utils/heartbeat
import ../[peerid, switch, multihash]
import ./protocol
import ./kademlia/[routing_table, protobuf, types, find, get, put, provider, ping]
import ./kademlia/kademlia_metrics

export
  chronicles, routing_table, protobuf, types, find, get, put, provider, ping,
  kademlia_metrics

logScope:
  topics = "kad-dht"

const KadCodec* = "/ipfs/kad/1.0.0"

proc refreshTable*(
    kad: KadDHT, rtable: RoutingTable, forceRefresh = false
) {.async: (raises: [CancelledError]).} =
  ## Sends a findNode to find itself to keep nearby peers up to date
  ## Also sends a findNode to find a random key for each non-empty k-bucket

  var targets = @[rtable.selfId]
  for i in 0 ..< rtable.buckets.len:
    let bucket = rtable.buckets[i]

    # skip empty buckets
    if bucket.peers.len == 0:
      continue

    # skip if refresh conditions not met (forceRefresh OR stale bucket)
    if not (forceRefresh or bucket.isStale()):
      continue

    let target = rtable.refreshTarget(i, kad.rng).valueOr:
      trace "No refresh target for bucket", bucket = i
      continue

    targets.add(target)

  let futs = targets.mapIt(kad.findNode(it, rtable))

  await allFutures(futs)

proc bootstrap*(
    kad: KadDHT, forceRefresh = false
) {.async: (raises: [CancelledError]).} =
  await kad.refreshTable(kad.rtable, forceRefresh)
  debug "Bootstrap complete"

proc maintainBuckets(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "Refreshing buckets", kad.config.bucketRefreshTime, sleepFirst = true:
    discard await kad.refreshTable(kad.rtable, false).withTimeout(
      kad.config.bucketRefreshTime
    )

# K instead of T to avoid clashing with the T type param in withValue[T] when
# called inside a withValue block, which causes a compiler error under --lineDir:on
proc new*(
    K: typedesc[KadDHT],
    switch: Switch,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: Rng,
    client: bool = false,
    codec: string = KadCodec,
): K {.raises: [].} =
  var rtable = RoutingTable.new(
    switch.peerInfo.peerId.toKey(),
    config = RoutingTableConfig.new(replication = config.replication),
  )
  let kad = K(
    rng: rng,
    switch: switch,
    rtable: rtable,
    config: config,
    providerManager:
      ProviderManager.new(config.providerRecordCapacity, config.providedKeyCapacity),
    rpcSem: newAsyncSemaphore(config.limits.maxConcurrentRpcs),
  )

  # Fill up buckets with initial bootstrap nodes
  kad.updatePeers(bootstrapNodes)

  kad.codec = codec
  if client:
    return kad

  kad.handler = proc(
      stream: Stream, proto: string
  ) {.async: (raises: [CancelledError]).} =
    defer:
      await stream.close()
    while not stream.atEof:
      var buf =
        try:
          await stream.readLp(MaxMsgSize)
        except LPStreamEOFError:
          return
        except LPStreamError as exc:
          debug "Read error when handling kademlia RPC", stream = stream, err = exc.msg
          return
      let bufLen = buf.len
      let msg = Message.decode(move(buf)).valueOr:
        debug "Failed to decode message", err = error
        return

      let msgType = msg.msgType.get(MessageType.putValue)

      kad_messages_received.inc(labelValues = [$msgType])
      kad_message_bytes_received.inc(bufLen.int64, labelValues = [$msgType])

      case msgType
      of MessageType.findNode:
        await kad.handleFindNode(stream, msg)
      of MessageType.putValue:
        await kad.handlePutValue(stream, msg)
      of MessageType.getValue:
        await kad.handleGetValue(stream, msg)
      of MessageType.addProvider:
        await kad.handleAddProvider(stream, msg)
      of MessageType.getProviders:
        await kad.handleGetProviders(stream, msg)
      of MessageType.ping:
        await kad.handlePing(stream, msg)
      of MessageType.register:
        trace "Unsupported message REGISTER"
        continue
      of MessageType.getAds:
        trace "Unsupported message GET_ADS"
        continue

  return kad

method start*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  if kad.started:
    warn "Starting kad-dht twice"
    return

  if not kad.config.disableBootstrapping:
    discard
      await kad.bootstrap(forceRefresh = true).withTimeout(kad.config.bucketRefreshTime)

  kad.maintenanceLoop = kad.maintainBuckets()
  kad.republishLoop = kad.manageRepublishProvidedKeys()
  kad.expiredLoop = kad.manageExpiredProviders()
  kad.recordExpirationLoop = kad.manageExpiredRecords()

  kad.started = true

  trace "Kad DHT started"

method stop*(kad: KadDHT) {.async: (raises: []).} =
  if not kad.started:
    return

  kad.started = false

  kad.maintenanceLoop.cancelSoon()
  kad.maintenanceLoop = nil

  kad.republishLoop.cancelSoon()
  kad.republishLoop = nil

  kad.expiredLoop.cancelSoon()
  kad.expiredLoop = nil

  kad.recordExpirationLoop.cancelSoon()
  kad.recordExpirationLoop = nil

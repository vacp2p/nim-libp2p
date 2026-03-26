# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, results
import ../utils/heartbeat
import ../[peerid, switch, multihash]
import ./protocol
import ./kademlia/[routingtable, protobuf, types, find, get, put, provider, ping]
import ./kademlia/kademlia_metrics

export routingtable, protobuf, types, find, get, put, provider, ping, kademlia_metrics

logScope:
  topics = "kad-dht"

const KadCodec = "/ipfs/kad/1.0.0"

proc bootstrap*(
    kad: KadDHT, forceRefresh = false
) {.async: (raises: [CancelledError]).} =
  ## Sends a findNode to find itself to keep nearby peers up to date
  ## Also sends a findNode to find a random key for each non-empty k-bucket

  kad.rtable.purgeExpired()

  discard await kad.findNode(kad.rtable.selfId)

  # Snapshot bucket count. findNode() can grow buckets and mutate length.
  # If it changes mid-iteration, Nim triggers an assertion defect.
  for i in 0 ..< kad.rtable.buckets.len:
    let bucket = kad.rtable.buckets[i]
    # skip empty buckets
    if bucket.peers.len == 0:
      continue
    # skip if refresh conditions not met (forceRefresh OR stale bucket) 
    if not (forceRefresh or bucket.isStale()):
      continue

    let randomKey = randomKeyInBucket(kad.rtable.selfId, i, kad.rng[])
    discard await kad.findNode(randomKey)

  trace "Bootstrap complete"

proc maintainBuckets(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "Refreshing buckets (bootstrapping)",
    kad.config.bucketRefreshTime, sleepFirst = true:
    await kad.bootstrap()

proc new*(
    T: typedesc[KadDHT],
    switch: Switch,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: ref HmacDrbgContext = newRng(),
    client: bool = false,
    codec: string = KadCodec,
): T {.raises: [].} =
  var rtable = RoutingTable.new(
    switch.peerInfo.peerId.toKey(),
    config = RoutingTableConfig.new(
      replication = config.replication, purgeStaleEntries = config.purgeStaleEntries
    ),
  )
  let kad = T(
    rng: rng,
    switch: switch,
    rtable: rtable,
    config: config,
    providerManager:
      ProviderManager.new(config.providerRecordCapacity, config.providedKeyCapacity),
  )

  # Fill up buckets with initial bootstrap nodes
  kad.updatePeers(bootstrapNodes)

  kad.codec = codec
  if client:
    return kad

  kad.handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    defer:
      await conn.close()
    while not conn.atEof:
      let buf =
        try:
          await conn.readLp(MaxMsgSize)
        except LPStreamEOFError:
          return
        except LPStreamError as exc:
          debug "Read error when handling kademlia RPC", conn = conn, err = exc.msg
          return
      let msg = Message.decode(buf).valueOr:
        debug "Failed to decode message", err = error
        return

      kad_messages_received.inc(labelValues = [$msg.msgType])
      kad_message_bytes_received.inc(buf.len.int64, labelValues = [$msg.msgType])

      case msg.msgType
      of MessageType.findNode:
        await kad.handleFindNode(conn, msg)
      of MessageType.putValue:
        await kad.handlePutValue(conn, msg)
      of MessageType.getValue:
        await kad.handleGetValue(conn, msg)
      of MessageType.addProvider:
        await kad.handleAddProvider(conn, msg)
      of MessageType.getProviders:
        await kad.handleGetProviders(conn, msg)
      of MessageType.ping:
        await kad.handlePing(conn, msg)

  return kad

method start*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  if kad.started:
    warn "Starting kad-dht twice"
    return

  await kad.bootstrap(forceRefresh = true)

  kad.maintenanceLoop = kad.maintainBuckets()
  kad.republishLoop = kad.manageRepublishProvidedKeys()
  kad.expiredLoop = kad.manageExpiredProviders()

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

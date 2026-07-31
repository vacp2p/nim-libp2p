# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, tables]
import chronos, chronicles, results
import ../utils/[heartbeat, future]
import ../[peerid, switch, multihash]
import ./protocol
import
  ./kademlia/[routing_table, protobuf, types, find, get, put, keyspace, provider, ping]
import ./kademlia/[kademlia_metrics, netsize]

export
  chronicles, routing_table, protobuf, types, find, get, put, keyspace, provider, ping,
  kademlia_metrics, netsize

logScope:
  topics = "kad-dht"

const KadCodec* = "/ipfs/kad/1.0.0"

proc livenessCandidates(
    rtable: RoutingTable, gracePeriod: Duration
): seq[PeerId] {.raises: [].} =
  ## Peers past the liveness grace period that should be probed.
  let now = Moment.now()
  var peers: seq[PeerId]
  for bucket in rtable.buckets:
    for entry in bucket.peers:
      if not entry.isReplaceable(gracePeriod, now):
        continue
      entry.nodeId.toPeerId().withValue(pid):
        peers.add(pid)
  peers

template withProbeSlotOrReturn*(kad: KadDHT) =
  ## Acquire one ``probeSem`` slot for the enclosing scope, or return without
  ## probing. Non-blocking: candidates that find no free slot are retried on a
  ## later pass rather than queued.
  if not kad.probeSem.tryAcquire():
    kad_routing_table_liveness_probes.inc(labelValues = ["skipped"])
    return
  defer:
    try:
      kad.probeSem.release()
    except AsyncSemaphoreError:
      raiseAssert "probeSem released without acquire"

proc checkAndEvictPeer(
    kad: KadDHT, rtable: RoutingTable, peerId: PeerId
) {.async: (raises: [CancelledError]).} =
  withProbeSlotOrReturn(kad)

  # Candidate list is a snapshot; by the time a slot is free the peer may have
  # been refreshed (markUseful) or removed, and stop may have begun.
  if kad.stopping:
    return
  let grace = kad.config.livenessGracePeriod
  if not rtable.isReplaceable(peerId, grace, Moment.now()):
    return

  let addrs = kad.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    trace "Evicting peer with no known addresses", peer = peerId.shortLog()
    discard rtable.removePeer(peerId, reason = "liveness")
    kad_routing_table_liveness_probes.inc(labelValues = ["no_addrs"])
    return

  if (await kad.lookupCheck(peerId, addrs)):
    rtable.markUseful(peerId)
    kad_routing_table_liveness_probes.inc(labelValues = ["ok"])
    return

  # Probe can race with unrelated traffic that markUseful'd the peer mid-flight.
  if not rtable.isReplaceable(peerId, grace, Moment.now()):
    return

  trace "Evicting unresponsive peer after liveness probe", peer = peerId.shortLog()
  discard rtable.removePeer(peerId, reason = "liveness")
  kad_routing_table_liveness_probes.inc(labelValues = ["fail"])

proc probeAndEvictPeers*(
    kad: KadDHT, rtable: RoutingTable
) {.async: (raises: [CancelledError]).} =
  ## Probes routing-table peers that have been quiet longer than the liveness
  ## grace period and removes those that fail to answer a FIND_NODE.
  if kad.stopping:
    return

  let candidates = rtable.livenessCandidates(kad.config.livenessGracePeriod)
  if candidates.len == 0:
    return

  var futs = newSeqOfCap[Future[void]](candidates.len)
  for peerId in candidates:
    futs.add(kad.checkAndEvictPeer(rtable, peerId))

  if futs.len > 0:
    try:
      await allFutures(futs)
    except CancelledError as exc:
      await noCancel futs.cancelAndWait()
      raise exc

proc refreshTable*(
    kad: KadDHT, rtable: RoutingTable, forceRefresh = false
) {.async: (raises: [CancelledError]).} =
  ## Sends a findNode to find itself to keep nearby peers up to date
  ## Also sends a findNode to find a random key for each non-empty k-bucket

  await kad.probeAndEvictPeers(rtable)

  discard await kad.findNode(rtable.selfId)

  var targets = newSeqOfCap[Key](rtable.buckets.len)
  for i in 0 ..< rtable.buckets.len:
    let bucket = rtable.buckets[i]

    # skip empty buckets
    if bucket.peers.len == 0:
      continue

    # skip if refresh conditions not met (forceRefresh OR stale bucket)
    if not (forceRefresh or bucket.isStale(rtable.config.bucketStaleTime)):
      continue

    let target = rtable.refreshTarget(i, kad.rng).valueOr:
      trace "No refresh target for bucket", bucket = i
      continue

    targets.add(target)

  let futs = targets.mapIt(kad.findNode(it, rtable))

  try:
    await allFutures(futs)
  except CancelledError as exec:
    await noCancel futs.cancelAndWait()
    raise exec

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

proc initKadBase*(
    kad: KadDHT, switch: Switch, config: KadDHTConfig, rng: Rng, isServer: bool
) {.raises: [].} =
  ## Set the shared fields in one place, so a new base field cannot miss a constructor.
  kad.rng = rng
  kad.switch = switch
  kad.rtable = RoutingTable.new(
    switch.peerInfo.peerId.toKey(),
    config = RoutingTableConfig.new(
      replication = config.replication,
      usefulnessGracePeriod = config.usefulnessGracePeriod,
      bucketStaleTime = config.bucketStaleTime,
    ),
  )
  kad.config = config
  kad.providerManager =
    ProviderManager.new(config.providerRecordCapacity, config.providedKeyCapacity)
  kad.nsEstimator = NetworkSizeEstimator.new(config.replication)
  kad.rpcSem = newAsyncSemaphore(config.limits.maxConcurrentRpcs)
  kad.probeSem = newAsyncSemaphore(config.limits.maxConcurrentProbes)
  kad.isServer = isServer

# K instead of T to avoid clashing with the T type param in withValue[T] when
# called inside a withValue block, which causes a compiler error under --lineDir:on
proc new*(
    K: typedesc[KadDHT],
    switch: Switch,
    bootstrapNodes: seq[(PeerId, seq[MultiAddress])] = @[],
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: Rng,
    isServer: bool = true,
    codec: string = KadCodec,
): K {.raises: [].} =
  let kad = K()
  kad.initKadBase(switch, config, rng, isServer)

  # Fill up buckets with initial bootstrap nodes
  kad.updatePeers(bootstrapNodes)

  kad.codec = codec

  kad.handler = proc(
      stream: Stream, proto: string
  ) {.async: (raises: [CancelledError]).} =
    if not kad.isServer:
      trace "Refusing inbound query while not serving", stream
      await stream.reset()
      return

    kad.serverStreams.incl(stream)
    defer:
      kad.serverStreams.excl(stream)
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

proc resetServerStreams(kad: KadDHT) {.async: (raises: []).} =
  let streams = kad.serverStreams
  kad.serverStreams.clear()
  await noCancel allFutures(streams.mapIt(it.reset()))
  debug "Reset inbound Kad DHT streams", streams = streams.len

proc changeMode*(kad: KadDHT, isServer: bool): Future[bool] {.async: (raises: []).} =
  ## Start or stop serving inbound queries, and report whether the mode changed.
  ## Stopping resets the in-flight inbound streams; the codec stays mounted (no
  ## unmount exists), so peers drop us once the handler refuses to serve.
  if isServer == kad.isServer:
    return false

  kad.isServer = isServer
  if not isServer:
    await kad.resetServerStreams()
  debug "Kad DHT changed mode", isServer
  true

method start*(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  if kad.started:
    warn "Starting kad-dht twice"
    return

  kad.stopping = false

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

  # Set before any await so handlers racing shutdown stop launching probes; the
  # drain loop below can then finish for good rather than chasing new arrivals.
  kad.stopping = true
  kad.started = false

  await noCancel allFutures(
    kad.maintenanceLoop.cancelAndWait(),
    kad.republishLoop.cancelAndWait(),
    kad.expiredLoop.cancelAndWait(),
    kad.recordExpirationLoop.cancelAndWait(),
  )
  kad.maintenanceLoop = nil
  kad.republishLoop = nil
  kad.expiredLoop = nil
  kad.recordExpirationLoop = nil

  # loop: a handler racing shutdown can register a probe while we await a batch
  while kad.admissionProbes.len > 0:
    let admissionProbes = move kad.admissionProbes
    await noCancel admissionProbes.values.toSeq().cancelAndWait()

  # Optimistic provide returns before its ADD_PROVIDER RPCs finish.
  let provideTasks = move kad.provideTasks
  await noCancel provideTasks.cancelAndWait()

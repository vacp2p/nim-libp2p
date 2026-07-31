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

proc peersInGracePeriod(
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

method maintainableTables*(kad: KadDHT): seq[RoutingTable] {.base, gcsafe, raises: [].} =
  ## Routing tables the liveness loop should keep healthy. Service discovery
  ## overrides this to include per-service tables.
  @[kad.rtable]

proc trackLivenessProbe(
    kad: KadDHT, probeKey: ProbeKey, probe: Future[void]
) {.raises: [].} =
  ## ``probe`` may already be done — a dial can fail without ever suspending.
  if probe.finished():
    return
  kad.livenessProbes[probeKey] = probe
  probe.addCallback(
    proc(udata: pointer) {.gcsafe, raises: [].} =
      if kad.livenessProbes.getOrDefault(probeKey) == probe:
        kad.livenessProbes.del(probeKey)
  )

proc checkAndEvictPeer(
    kad: KadDHT, rtable: RoutingTable, peerId: PeerId
) {.async: (raises: [CancelledError]).} =
  ## Takes ownership of one ``probeSem`` slot already acquired by the caller.
  defer:
    try:
      kad.livenessSem.release()
    except AsyncSemaphoreError:
      raiseAssert "livenessSem released without acquire"

  # Candidate list is a snapshot; by the time a slot is free the peer may have
  # been refreshed (markUseful) or removed, and stop may have begun.
  if kad.stopping:
    return
  let grace = kad.config.livenessGracePeriod
  var dueTables: seq[RoutingTable]
  for rtable in kad.maintainableTables():
    if rtable.isReplaceable(peerId, grace, Moment.now()):
      dueTables.add(rtable)
  if dueTables.len == 0:
    debug "Liveness probe skipped: peer no longer replaceable", peer = peerId.shortLog()
    return

  let addrs = kad.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    var evicted = 0
    for rtable in dueTables:
      # Re-check: peer may have been markUseful'd after the snapshot.
      if not rtable.isReplaceable(peerId, grace, Moment.now()):
        continue
      discard rtable.removePeer(peerId, reason = "liveness")
      inc evicted
    if evicted > 0:
      debug "Evicting peer with no known addresses",
        peer = peerId.shortLog(), tables = evicted
      kad_routing_table_liveness_probes.inc(labelValues = ["no_addrs"])
    else:
      debug "Liveness probe skipped: peer no longer replaceable",
        peer = peerId.shortLog()
    return

  debug "Probing peer for liveness", peer = peerId.shortLog(), tables = dueTables.len
  if (await kad.lookupCheck(peerId, addrs)):
    debug "Liveness probe succeeded", peer = peerId.shortLog()
    # Peer is reachable: refresh usefulness on every table that holds it.
    for rtable in kad.maintainableTables():
      rtable.markUseful(peerId)
    kad_routing_table_liveness_probes.inc(labelValues = ["ok"])
    return

  # Probe can race with unrelated traffic that markUseful'd the peer mid-flight.
  var evicted = 0
  for rtable in kad.maintainableTables():
    if not rtable.isReplaceable(peerId, grace, Moment.now()):
      continue
    discard rtable.removePeer(peerId, reason = "liveness")
    inc evicted
  if evicted == 0:
    debug "Liveness probe failed but peer refreshed mid-flight",
      peer = peerId.shortLog()
    return

  debug "Evicting unresponsive peer after liveness probe",
    peer = peerId.shortLog(), tables = evicted
  kad_routing_table_liveness_probes.inc(labelValues = ["fail"])

proc tryLaunchLivenessProbe(
    kad: KadDHT, rtable: RoutingTable, peerId: PeerId
): bool {.raises: [].} =
  ## Non-blocking launch of a liveness probe. Returns true when a probe was
  ## started (or was already in flight). False when the shared probe semaphore
  ## has no free slot — the caller should wait and retry.
  let probeKey: ProbeKey = (rtable.selfId, peerId)
  if kad.livenessProbes.hasKey(probeKey):
    return true
  if kad.stopping:
    return true
  if not kad.probeSem.tryAcquire():
    kad_routing_table_liveness_probes.inc(labelValues = ["skipped"])
    return false
  kad.trackLivenessProbe(probeKey, kad.checkAndEvictPeer(rtable, peerId))
  true

proc probeAndEvictPeers*(
    kad: KadDHT, rtable: RoutingTable
) {.async: (raises: [CancelledError]).} =
  ## One-shot batch: probes routing-table peers past the liveness grace period
  ## and removes those that fail to answer a FIND_NODE. Used by tests and any
  ## explicit maintenance call; production traffic uses ``maintainLiveness``.
  if kad.stopping:
    return

  let peers = rtable.peersInGracePeriod(kad.config.livenessGracePeriod)
  if peers.len == 0:
    return

  var futs = newSeqOfCap[Future[void]](candidates.len)
  for peerId in candidates:
    let probeKey: ProbeKey = (rtable.selfId, peerId)
    kad.livenessProbes.withValue(probeKey, existing):
      futs.add(existing[])
      continue
    if not kad.probeSem.tryAcquire():
      kad_routing_table_liveness_probes.inc(labelValues = ["skipped"])
      continue
    let fut = kad.checkAndEvictPeer(rtable, peerId)
    kad.trackLivenessProbe(probeKey, fut)
    futs.add(fut)

  if futs.len > 0:
    try:
      await allFutures(futs)
    except CancelledError as exc:
      await noCancel futs.cancelAndWait()
      raise exc
  debug "Liveness batch complete", peers = peers.len

proc maintainLiveness(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  ## Continuous background task: drain replaceable peers via liveness probes
  ## as soon as they become due, bounded by ``livenessSem``. Independent of
  ## bucket refresh so dead peers are not held until the next refresh tick.
  ## At most one probe is in flight per peer across all maintainable tables.

  while not kad.stopping:
    # Initial idle: let start() finish bootstrap before the first scan.
    await sleepAsync(kad.config.livenessIdleInterval)

    let grace = kad.config.livenessGracePeriod

    for rtable in kad.maintainableTables():
      if kad.stopping:
        return
      let peers = rtable.peersInGracePeriod(grace)
      if peers.len > 0:
        debug "Liveness scan found replaceable peers", peers = peers.len
      for peerId in peers:
        kad.launchLivenessProbe(peerId)

    if kad.livenessProbes.len > 0:
      debug "Waiting for in-flight liveness probes", inFlight = kad.livenessProbes.len
      let inFlight = kad.livenessProbes.values.toSeq()
      try:
        discard await one(inFlight)
      except ValueError:
        # All futures already finished between the snapshot and the wait.
        discard
      except CancelledError as exc:
        await noCancel inFlight.cancelAndWait()
        raise exc

proc maintainLiveness(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  ## Continuous background task: drain replaceable peers via liveness probes
  ## as soon as they become due, bounded by ``probeSem``. Independent of
  ## bucket refresh so dead peers are not held until the next refresh tick.
  # Yield once so start() can finish bootstrap before the first scan.
  await sleepAsync(kad.config.livenessIdleInterval)

  while not kad.stopping:
    let grace = kad.config.livenessGracePeriod
    var saturated = false

    for rtable in kad.maintainableTables():
      if kad.stopping:
        return
      for peerId in rtable.livenessCandidates(grace):
        if not kad.tryLaunchLivenessProbe(rtable, peerId):
          saturated = true
          break
      if saturated:
        break

    if kad.livenessProbes.len > 0:
      let inFlight = kad.livenessProbes.values.toSeq()
      try:
        discard await one(inFlight)
      except ValueError:
        # All futures already finished between the snapshot and the wait.
        discard
      except CancelledError as exc:
        await noCancel inFlight.cancelAndWait()
        raise exc
    else:
      await sleepAsync(kad.config.livenessIdleInterval)

proc refreshTable*(
    kad: KadDHT, rtable: RoutingTable, forceRefresh = false
) {.async: (raises: [CancelledError]).} =
  ## Sends a findNode to find itself to keep nearby peers up to date
  ## Also sends a findNode to find a random key for each non-empty k-bucket.

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
    config = RoutingTableConfig.new(
      replication = config.replication,
      usefulnessGracePeriod = config.usefulnessGracePeriod,
      bucketStaleTime = config.bucketStaleTime,
    ),
  )
  let kad = K(
    rng: rng,
    switch: switch,
    rtable: rtable,
    config: config,
    providerManager:
      ProviderManager.new(config.providerRecordCapacity, config.providedKeyCapacity),
    nsEstimator: NetworkSizeEstimator.new(config.replication),
    rpcSem: newAsyncSemaphore(config.limits.maxConcurrentRpcs),
    admissionSem: newAsyncSemaphore(config.limits.maxConcurrentProbes),
    livenessSem: newAsyncSemaphore(config.limits.maxConcurrentLivenessProbes),
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

  kad.stopping = false

  if not kad.config.disableBootstrapping:
    discard
      await kad.bootstrap(forceRefresh = true).withTimeout(kad.config.bucketRefreshTime)

  kad.maintenanceLoop = kad.maintainBuckets()
  kad.livenessLoop = kad.maintainLiveness()
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
    kad.livenessLoop.cancelAndWait(),
    kad.republishLoop.cancelAndWait(),
    kad.expiredLoop.cancelAndWait(),
    kad.recordExpirationLoop.cancelAndWait(),
  )
  kad.maintenanceLoop = nil
  kad.livenessLoop = nil
  kad.republishLoop = nil
  kad.expiredLoop = nil
  kad.recordExpirationLoop = nil

  # loop: a handler racing shutdown can register a probe while we await a batch
  while kad.admissionProbes.len > 0 or kad.livenessProbes.len > 0:
    let admissionProbes = move kad.admissionProbes
    let livenessProbes = move kad.livenessProbes
    await noCancel allFutures(
      admissionProbes.values.toSeq().cancelAndWait(),
      livenessProbes.values.toSeq().cancelAndWait(),
    )

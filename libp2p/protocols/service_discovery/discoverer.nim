# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets, tables]
import chronos, chronicles, results
import ../../[peerid, switch, multiaddress, extended_peer_record]
import ../../utils/heartbeat
import ../kademlia
import ../kademlia/types
import
  ./[types, routing_table_manager, service_discovery_metrics, registrar, connection]

logScope:
  topics = "service-disco discoverer"

type GetAdsResult = object
  ads: seq[Advertisement]
  closerPeers: seq[PeerInfo]

proc validAds(ads: seq[seq[byte]], serviceId: ServiceId): seq[Advertisement] =
  var validAds: seq[Advertisement] = @[]
  for adBuf in ads:
    let ad = Advertisement.decode(adBuf).valueOr:
      error "failed to decode advertisement", error
      continue

    if not ad.advertisesService(serviceId):
      error "advert service mismatch", serviceId
      continue

    validAds.add(ad)
  return validAds

proc localGetAds(disco: ServiceDiscovery, msg: Message): Result[Message, string] =
  return ok(disco.getAdvertisements(msg))

proc dispatchGetAds(
    disco: ServiceDiscovery, peerId: PeerId, serviceId: ServiceId
): Future[Result[GetAdsResult, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  debug "getting adverts", serviceId, registrar = peerId

  let msg = Message(msgType: MessageType.getAds, key: serviceId)

  let replyRes =
    if peerId == disco.switch.peerInfo.peerId:
      disco.localGetAds(msg)
    else:
      await disco.send(peerId, msg)

  let reply = replyRes.valueOr:
    return err($error)

  let getAdsMsg = reply.getAds.valueOr:
    return err("get ads message response not found")

  debug "adverts found",
    serviceId, remote = peerId, count = getAdsMsg.advertisements.len

  return ok(
    GetAdsResult(
      ads: getAdsMsg.advertisements.validAds(serviceId),
      closerPeers: reply.closerPeers.toPeerInfos(),
    )
  )

proc peersToQuery(disco: ServiceDiscovery, bucket: Bucket): seq[PeerId] =
  let peersToPick = min(disco.discoConfig.kLookup, bucket.peers.len)
  disco.rng.pick(bucket.peers, peersToPick).withValue(picked):
    return picked.toPeerIds()
  else:
    return @[]

proc insertCloserPeers(
    disco: ServiceDiscovery, serviceId: ServiceId, peers: seq[PeerId]
) =
  for nodeId in peers:
    disco.rtManager.insertPeer(serviceId, nodeId.toKey())

proc processResponse(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    response: GetAdsResult,
    found: var seq[Advertisement],
    limit: int,
) =
  disco.updatePeers(response.closerPeers)

  disco.insertCloserPeers(serviceId, response.closerPeers.mapIt(it.peerId))
  let remaining = limit - found.len
  if remaining > 0:
    found.add(response.ads[0 ..< min(remaining, response.ads.len)])

proc drainCompletedPeers(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    pending: seq[Future[Result[GetAdsResult, string]]],
) =
  for fut in pending.filterIt(it.completed()):
    let res = fut.value()
    if res.isOk():
      disco.insertCloserPeers(serviceId, res.value().closerPeers.mapIt(it.peerId))

proc collectBucketAds(
    disco: ServiceDiscovery, serviceId: ServiceId, peers: seq[PeerId], limit: int
): Future[seq[Advertisement]] {.async: (raises: [CancelledError]).} =
  var found = newSeqOfCap[Advertisement](limit)
  var pending: seq[Future[Result[GetAdsResult, string]]] = peers.mapIt(
    Future[Result[GetAdsResult, string]](dispatchGetAds(disco, it, serviceId))
  )
  defer:
    for fut in pending:
      if not fut.finished():
        fut.cancelSoon()

  let deadline = Moment.fromNow(disco.config.timeout)
  for _ in 0 ..< pending.len:
    let timeLeft = deadline - Moment.now()
    if timeLeft <= ZeroDuration:
      break

    let wrapper = one(pending)
    if not (await wrapper.withTimeout(timeLeft)):
      break

    let completedFut = wrapper.value()
    pending.del(pending.find(completedFut))

    if completedFut.completed():
      let res = completedFut.value()
      if res.isOk():
        disco.processResponse(serviceId, res.value(), found, limit)

    if found.len >= limit:
      disco.drainCompletedPeers(serviceId, pending)
      break

  return found

proc mergeAds(
    existing, incoming: seq[Advertisement]
): seq[Advertisement] {.raises: [].} =
  var best: Table[PeerId, Advertisement]
  for ad in existing & incoming:
    let pid = ad.data.peerId
    best.withValue(pid, curr):
      if ad.data.seqNo > curr[].data.seqNo:
        curr[] = ad
    do:
      best[pid] = ad
  return toSeq(best.values)

proc fetchRemoteAds(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    limit: int,
    includeLocal: bool = false,
): Future[seq[Advertisement]] {.async: (raises: [CancelledError]).} =
  let searchTable = disco.rtManager.getTable(serviceId).valueOr:
    return @[]

  var found = newSeqOfCap[Advertisement](limit)
  var addedLocal = not includeLocal

  # snapshot buckets: insertCloserPeers (called during await) can add
  # new buckets to the live RoutingTable ref, invalidating the iterator
  let buckets = searchTable.buckets
  for bucket in buckets:
    if found.len >= limit:
      break

    if bucket.peers.len == 0:
      continue

    var peers = disco.peersToQuery(bucket)

    if not addedLocal:
      peers.add(disco.switch.peerInfo.peerId)
      addedLocal = true

    let remaining = limit - found.len
    found.add(await disco.collectBucketAds(serviceId, peers, remaining))

  return found

proc discoverFromRegistrar(
    disco: ServiceDiscovery, serviceId: ServiceId
) {.async: (raises: [CancelledError]).} =
  heartbeat "discover service ads", disco.discoConfig.advertExpiry:
    let remoteAds = await disco.fetchRemoteAds(serviceId, disco.discoConfig.fLookup)
    disco.discoverer.cache[serviceId] =
      mergeAds(disco.discoverer.cache.getOrDefault(serviceId, @[]), remoteAds)

proc addDiscoveredService*(disco: ServiceDiscovery, service: ServiceInfo): bool =
  let sid = toServiceId(service)

  if disco.discoverer.running.anyIt(it.serviceId == sid):
    return false

  debug "start discovering", service = service.id, serviceId = sid

  discard disco.rtManager.addService(
    sid, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Interest,
  )

  let fut = disco.discoverFromRegistrar(sid)
  disco.discoverer.running.incl(DiscoverTask(fut: fut, serviceId: sid))
  return true

proc startDiscovering*(disco: ServiceDiscovery, service: ServiceInfo): bool =
  disco.addDiscoveredService(service)

proc stopDiscovering*(
    disco: ServiceDiscovery, service: ServiceInfo
) {.async: (raises: [CancelledError]).} =
  let sid = toServiceId(service)

  debug "stop discovering", service = service.id, serviceId = sid

  var toRemove: HashSet[DiscoverTask]
  for t in disco.discoverer.running.filterIt(it.serviceId == sid):
    await t.fut.cancelAndWait()
    toRemove.incl(t)
  disco.discoverer.running.excl(toRemove)

  disco.discoverer.cache.del(sid)
  disco.rtManager.removeService(sid, Interest)

proc lookup*(
    disco: ServiceDiscovery, serviceId: ServiceId
): Future[Result[seq[Advertisement], string]] {.async: (raises: [CancelledError]).} =
  ## Look up providers for a specific service id.
  cd_lookup_requests.inc()

  let hasActiveDiscovery = disco.discoverer.running.anyIt(it.serviceId == serviceId)

  # Return cache immediately if it already has enough entries
  if hasActiveDiscovery:
    let cached = disco.discoverer.cache.getOrDefault(serviceId, @[])
    if cached.len >= disco.discoConfig.fLookup:
      cd_lookup_peers_found.inc(cached.len.int64)
      return ok(cached)

  # Ensure a routing table exists; remove it on exit for one-shot callers
  discard disco.rtManager.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Interest,
  )
  defer:
    if not disco.discoverer.running.anyIt(it.serviceId == serviceId):
      disco.rtManager.removeService(serviceId, Interest)

  let remoteAds = await disco.fetchRemoteAds(
    serviceId, disco.discoConfig.fLookup, includeLocal = not hasActiveDiscovery
  )

  let found =
    if hasActiveDiscovery:
      let merged =
        mergeAds(disco.discoverer.cache.getOrDefault(serviceId, @[]), remoteAds)
      disco.discoverer.cache[serviceId] = merged
      merged
    else:
      remoteAds

  cd_lookup_peers_found.inc(found.len.int64)
  return ok(found)

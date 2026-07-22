# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets]
import chronos, chronicles, results
import ../../[peerid, switch, multiaddress, extended_peer_record]
import ../kademlia
import ../kademlia/types
import
  ./[types, routing_table_manager, service_discovery_metrics, registrar, connection]
import ../../utils/future

logScope:
  topics = "service-disco discoverer"

type GetAdsResult = object
  ads: seq[Advertisement]
  closerPeers: seq[PeerInfo]

proc validAds(ads: seq[seq[byte]], serviceId: ServiceId): seq[Advertisement] =
  var validAds: seq[Advertisement] = @[]
  for adBuf in ads:
    if adBuf.len == 0 or adBuf.len > MaxXPRSize:
      continue

    let ad = Advertisement.decode(adBuf).valueOr:
      error "failed to decode advertisement", error
      continue

    if not ad.advertisesService(serviceId):
      error "advert service mismatch", serviceId
      continue

    if not ad.isValid():
      error "advertisement violates XPR or ServiceInfo size limits", serviceId
      continue

    validAds.add(ad)
  return validAds

proc localGetAds(disco: ServiceDiscovery, msg: Message): Result[Message, string] =
  return ok(disco.getAdvertisements(disco.switch.peerInfo.peerId, msg))

proc dispatchGetAds(
    disco: ServiceDiscovery, peerId: PeerId, serviceId: ServiceId
): Future[Result[GetAdsResult, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  debug "getting adverts", serviceId, registrar = peerId

  let msg = Message(msgType: Opt.some(MessageType.getAds), key: Opt.some(serviceId))

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
    disco: ServiceDiscovery, serviceId: ServiceId, peers: seq[PeerInfo]
) =
  for peerInfo in peers:
    discard disco.insertPeer(serviceId, peerInfo)

proc processResponse(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    response: GetAdsResult,
    found: var HashSet[Advertisement],
    limit: int,
) =
  disco.updatePeers(response.closerPeers)

  disco.insertCloserPeers(serviceId, response.closerPeers)
  for ad in response.ads:
    if found.len >= limit:
      break
    found.incl(ad)

proc drainCompletedPeers(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    pending: seq[Future[Result[GetAdsResult, string]]],
) =
  for fut in pending.filterIt(it.completed()):
    let res = fut.value()
    if res.isOk():
      disco.insertCloserPeers(serviceId, res.value().closerPeers)

proc collectBucketAds(
    disco: ServiceDiscovery, serviceId: ServiceId, peers: seq[PeerId], limit: int
): Future[HashSet[Advertisement]] {.async: (raises: [CancelledError]).} =
  var found = initHashSet[Advertisement]()
  var pending: seq[Future[Result[GetAdsResult, string]]] = peers.mapIt(
    Future[Result[GetAdsResult, string]](dispatchGetAds(disco, it, serviceId))
  )
  defer:
    pending.cancelSoon()

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

proc registerInterest*(disco: ServiceDiscovery, serviceId: string): bool =
  ## Register interest in a service so its routing table is created and kept
  ## fresh by the refresh loop. No messages are sent and no ads are fetched
  ## here. This only prepopulates the per-service routing table to make subsequent
  ## `lookup` calls faster.
  let serviceHash = serviceId.hashServiceId()

  debug "register interest", service = serviceId, serviceId = serviceHash

  disco.rtManager.addService(
    serviceHash, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Interest,
  )

proc unregisterInterest*(disco: ServiceDiscovery, serviceId: string) =
  ## Drop interest in a service. The per-service routing table is removed
  ## unless this node is also providing the service, in which case the table
  ## is kept for advertising.
  let serviceHash = serviceId.hashServiceId()

  debug "unregister interest", service = serviceId, serviceId = serviceHash

  disco.rtManager.removeService(serviceHash, Interest)

proc lookup*(
    disco: ServiceDiscovery, serviceId: ServiceId
): Future[Result[seq[Advertisement], string]] {.async: (raises: [CancelledError]).} =
  ## Look up providers for a specific service id.
  cd_lookup_requests.inc()

  discard disco.rtManager.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Interest,
  )

  let searchTable = disco.rtManager.getTable(serviceId).valueOr:
    return err("service table not found for service id: " & $serviceId)

  var found = initHashSet[Advertisement]()
  var once = true

  let buckets = searchTable.buckets
  for bucket in buckets:
    if found.len >= disco.discoConfig.fLookup:
      break

    if bucket.peers.len == 0:
      continue

    var peers = disco.peersToQuery(bucket)

    if once:
      peers.add(disco.switch.peerInfo.peerId)
      once = false

    let remaining = disco.discoConfig.fLookup - found.len
    found.incl(await disco.collectBucketAds(serviceId, peers, remaining))

  cd_lookup_peers_found.inc(found.len.int64)
  return ok(found.toSeq)

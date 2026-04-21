# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/sequtils
import chronos, chronicles, results
import ../../[peerid, switch, multiaddress, extended_peer_record]
import ../kademlia
import ../kademlia/types
import ./[types, routing_table_manager, service_discovery_metrics]

logScope:
  topics = "service-disco discoverer"

type GetAdsResult = object
  ads: seq[Advertisement]
  closerPeers: seq[PeerId]

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

proc dispatchGetAds(
    disco: ServiceDiscovery, peerId: PeerId, serviceId: ServiceId, limit: int
): Future[Opt[GetAdsResult]] {.async: (raises: [CancelledError]), gcsafe.} =
  let addrs = disco.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return Opt.none(GetAdsResult)

  let connRes = catch:
    await disco.switch.dial(peerId, addrs, disco.codec)
  let conn = connRes.valueOr:
    error "dialing peer failed", error = error.msg
    return Opt.none(GetAdsResult)
  defer:
    await conn.close()

  let msg = Message(
    msgType: MessageType.getAds,
    key: serviceId,
    getAds: Opt.some(GetAdsMessage(limit: limit.uint32)),
  )
  let encodedMsg = msg.encode().buffer

  cd_messages_sent.inc(labelValues = [$MessageType.getAds])
  cd_message_bytes_sent.inc(encodedMsg.len.float64, labelValues = [$MessageType.getAds])

  var writeRes: Result[void, ref CatchableError]
  var readRes: Result[seq[byte], ref CatchableError]
  cd_message_duration_ms.time(labelValues = [$MessageType.getAds]):
    writeRes = catch:
      await conn.writeLp(encodedMsg)

  if writeRes.isErr:
    error "connection writing failed", error = writeRes.error.msg
    return Opt.none(GetAdsResult)

  cd_message_duration_ms.time(labelValues = [$MessageType.getAds]):
    readRes = catch:
      await conn.readLp(MaxMsgSize)
  let replyBuf = readRes.valueOr:
    error "connection reading failed", error = readRes.error.msg
    return Opt.none(GetAdsResult)

  cd_messages_received.inc(labelValues = [$MessageType.getAds])
  cd_message_bytes_received.inc(
    replyBuf.len.float64, labelValues = [$MessageType.getAds]
  )

  let reply = Message.decode(replyBuf).valueOr:
    error "failed to decode message response", error = $error
    return Opt.none(GetAdsResult)

  let getAdsMsg = reply.getAds.valueOr:
    error "get ads message response not found"
    return Opt.none(GetAdsResult)

  var closerPeerInfos: seq[PeerInfo]
  for peer in reply.closerPeers:
    let pid = PeerId.init(peer.id).valueOr:
      continue
    closerPeerInfos.add(PeerInfo(peerId: pid, addrs: peer.addrs))
  disco.updatePeers(closerPeerInfos)

  return Opt.some(
    GetAdsResult(
      ads: getAdsMsg.advertisements.validAds(serviceId),
      closerPeers: closerPeerInfos.mapIt(it.peerId),
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
  disco.insertCloserPeers(serviceId, response.closerPeers)
  let remaining = limit - found.len
  if remaining > 0:
    found.add(response.ads[0 ..< min(remaining, response.ads.len)])

proc drainCompletedPeers(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    pending: seq[Future[Opt[GetAdsResult]]],
) =
  for fut in pending.filterIt(it.completed()):
    fut.value().withValue(response):
      disco.insertCloserPeers(serviceId, response.closerPeers)

proc collectBucketAds(
    disco: ServiceDiscovery, serviceId: ServiceId, peers: seq[PeerId], limit: int
): Future[seq[Advertisement]] {.async: (raises: [CancelledError]).} =
  var found = newSeqOfCap[Advertisement](limit)
  var pending: seq[Future[Opt[GetAdsResult]]] =
    peers.mapIt(Future[Opt[GetAdsResult]](dispatchGetAds(disco, it, serviceId, limit)))
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
      completedFut.value().withValue(response):
        disco.processResponse(serviceId, response, found, limit)

    if found.len >= limit:
      disco.drainCompletedPeers(serviceId, pending)
      break

  return found

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

  var found = newSeqOfCap[Advertisement](disco.discoConfig.fLookup)

  for bucket in searchTable.buckets:
    if found.len >= disco.discoConfig.fLookup:
      break

    if bucket.peers.len == 0:
      continue

    let remaining = disco.discoConfig.fLookup - found.len
    found.add(
      await disco.collectBucketAds(serviceId, disco.peersToQuery(bucket), remaining)
    )

  cd_lookup_peers_found.inc(found.len.int64)
  return ok(found)

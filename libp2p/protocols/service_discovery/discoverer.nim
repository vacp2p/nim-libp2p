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

proc dispatchGetAds(
    disco: ServiceDiscovery, peerId: PeerId, serviceId: ServiceId, limit: int
): Future[Result[GetAdsResult, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let addrs = disco.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return err("no addresses for peer")

  debug "getting adverts", serviceId, remote = peerId

  let connRes = catch:
    await disco.switch.dial(peerId, addrs, disco.codec)
  if connRes.isErr:
    error "dialing peer failed", error = connRes.error.msg
    return err(connRes.error.msg)
  let conn = connRes.value()
  defer:
    await conn.close()

  let msg = Message(msgType: MessageType.getAds, key: serviceId)
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
    return err(writeRes.error.msg)

  cd_message_duration_ms.time(labelValues = [$MessageType.getAds]):
    readRes = catch:
      await conn.readLp(MaxMsgSize)
  if readRes.isErr:
    error "connection reading failed", error = readRes.error.msg
    return err(readRes.error.msg)
  let replyBuf = readRes.value()

  cd_messages_received.inc(labelValues = [$MessageType.getAds])
  cd_message_bytes_received.inc(
    replyBuf.len.float64, labelValues = [$MessageType.getAds]
  )

  let reply = Message.decode(replyBuf).valueOr:
    error "failed to decode message response", error = $error
    return err("failed to decode message response")

  let getAdsMsg = reply.getAds.valueOr:
    error "get ads message response not found"
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
    Future[Result[GetAdsResult, string]](dispatchGetAds(disco, it, serviceId, limit))
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

proc startDiscovering*(disco: ServiceDiscovery, serviceId: string): bool =
  let serviceHash = serviceId.hashServiceId()

  debug "start discovering", service = serviceId, serviceId = serviceHash

  disco.rtManager.addService(
    serviceHash, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Interest,
  )

proc stopDiscovering*(disco: ServiceDiscovery, serviceId: string) =
  let serviceHash = serviceId.hashServiceId()

  debug "stop discovering", service = serviceId, serviceId = serviceHash

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

  var found = newSeqOfCap[Advertisement](disco.discoConfig.fLookup)

  let buckets = searchTable.buckets
  for bucket in buckets:
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

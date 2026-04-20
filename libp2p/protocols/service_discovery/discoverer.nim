# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/sequtils
import chronos, chronicles, results
import ../../[peerid, switch, multiaddress, extended_peer_record, utility]
import ../kademlia
import ../kademlia/[types, protobuf as kademlia_protobuf]
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
    disco: ServiceDiscovery, peerId: PeerId, serviceId: ServiceId
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

  let msg = Message(msgType: MessageType.getAds, key: serviceId)
  let encodedMsg = msg.encode().buffer

  cd_messages_sent.inc(labelValues = [$MessageType.getAds])
  cd_message_bytes_sent.inc(encodedMsg.len.float64, labelValues = [$MessageType.getAds])

  var writeRes: Result[void, ref CatchableError]
  var readRes: Result[seq[byte], ref CatchableError]
  cd_message_duration_ms.time(labelValues = [$MessageType.getAds]):
    writeRes = catch:
      await conn.writeLp(encodedMsg)
    readRes = catch:
      await conn.readLp(MaxMsgSize)

  if writeRes.isErr:
    error "connection writing failed", error = writeRes.error.msg
    return Opt.none(GetAdsResult)
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

    let peers = disco.peersToQuery(bucket)

    let
      rpcBatch = peers.mapIt(dispatchGetAds(disco, it, serviceId))
      completedBatch = await rpcBatch.collectCompleted(disco.config.timeout)

    for res in completedBatch:
      res.withValue(val):
        for nodeId in val.closerPeers:
          disco.rtManager.insertPeer(serviceId, nodeId.toKey())
        let remaining = disco.discoConfig.fLookup - found.len
        if remaining > 0:
          found.add(val.ads[0 ..< min(remaining, val.ads.len)])

  cd_lookup_peers_found.inc(found.len.int64)
  return ok(found)

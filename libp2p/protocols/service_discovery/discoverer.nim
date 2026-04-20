# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, chronicles, results
import ../../[peerid, switch, multiaddress, extended_peer_record]
import ../kademlia
import ../kademlia/[types, protobuf as kademlia_protobuf]
import ./[types, routing_table_manager, service_discovery_metrics]

logScope:
  topics = "service-disco discoverer"

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

proc sendGetAds(
    disco: ServiceDiscovery, peerId: PeerId, serviceId: ServiceId
): Future[Result[(seq[Advertisement], seq[PeerId]), string]] {.
    async: (raises: [CancelledError])
.} =
  let addrs = disco.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return ok((@[], @[]))

  let connRes = catch:
    await disco.switch.dial(peerId, addrs, disco.codec)
  let conn = connRes.valueOr:
    return err("dialing peer failed: " & error.msg)
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
    return err("connection writing failed: " & writeRes.error.msg)
  let replyBuf = readRes.valueOr:
    return err("connection reading failed: " & readRes.error.msg)

  cd_messages_received.inc(labelValues = [$MessageType.getAds])
  cd_message_bytes_received.inc(
    replyBuf.len.float64, labelValues = [$MessageType.getAds]
  )

  let reply = Message.decode(replyBuf).valueOr:
    return err("failed to decode message response: " & $error)

  let getAdsMsg = reply.getAds.valueOr:
    return err("get ads message response not found")

  return
    ok((getAdsMsg.advertisements.validAds(serviceId), reply.closerPeers.toPeerIds()))

proc peersToQuery(bucket: Bucket, kLookup: int): seq[PeerId] =
  var peerIds: seq[PeerId]
  for i in 0 ..< min(kLookup, bucket.peers.len):
    let peerId = bucket.peers[i].nodeId.toPeerId().valueOr:
      error "cannot convert key to peer id", error
      continue
    peerIds.add(peerId)
  return peerIds

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

  for bucketIdx in 0 ..< searchTable.buckets.len:
    if found.len >= disco.discoConfig.fLookup: # done
      break

    var bucket = searchTable.buckets[bucketIdx]
    if bucket.peers.len == 0:
      continue

    disco.rng.shuffle(bucket.peers)

    for peerId in bucket.peersToQuery(disco.discoConfig.kLookup):
      let (ads, closerPeers) = (await sendGetAds(disco, peerId, serviceId)).valueOr:
        error "failed to get ads", error
        continue

      for nodeId in closerPeers:
        disco.rtManager.insertPeer(serviceId, nodeId.toKey())

      let remaining = disco.discoConfig.fLookup - found.len
      if remaining > 0:
        found.add(ads[0 ..< min(remaining, ads.len)])
      else:
        # done
        break

  cd_lookup_peers_found.inc(found.len.int64)
  return ok(found)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets]
import chronos, chronicles, results
import
  ../../[peerid, switch, multihash, cid, multicodec, multiaddress, extended_peer_record]
import ../../crypto/crypto
import ../kademlia
import ../kademlia/types
import ../kademlia/protobuf as kademlia_protobuf
import ../kademlia_discovery/types
import ./[types, serviceroutingtables]

logScope:
  topics = "cap-disco discoverer"

proc sendGetAds(
    disco: KademliaDiscovery, peerId: PeerId, serviceId: ServiceId
): Future[Result[(seq[Advertisement], seq[PeerId]), string]] {.async: (raises: []).} =
  ## Send GET_ADS request to a peer

  var validAds: seq[Advertisement] = @[]
  var peerIds: seq[PeerId] = @[]

  let addrs = disco.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return ok((validAds, peerIds))

  let connRes = catch:
    await disco.switch.dial(peerId, addrs, disco.codec)
  let conn = connRes.valueOr:
    return err("dialing peer failed: " & error.msg)
  defer:
    await conn.close()

  let msg = Message(msgType: MessageType.getAds, key: serviceId)

  let writeRes = catch:
    await conn.writeLp(msg.encode().buffer)
  if writeRes.isErr:
    return err("Connection writing failed: " & writeRes.error.msg)

  let readRes = catch:
    await conn.readLp(MaxMsgSize)
  let replyBuf = readRes.valueOr:
    return err("Connection reading failed: " & error.msg)

  let reply = Message.decode(replyBuf).valueOr:
    return err("failed to decode message response: " & $error)

  let getAdsMsg = reply.getAds.valueOr:
    return err("get ads message response not found")

  for adBuf in getAdsMsg.advertisements:
    let ad = Advertisement.decode(adBuf).valueOr:
      error "failed to decode advertisement", error
      continue

    if not ad.advertisesService(serviceId):
      error "advert service mismatch", serviceId
      continue

    validAds.add(ad)

  for peer in reply.closerPeers:
    let peerId = PeerId.init(peer.id).valueOr:
      error "failed to decode peer id", error
      continue

    peerIds.add(peerId)

  return ok((validAds, peerIds))

proc lookup*(
    disco: KademliaDiscovery, serviceId: ServiceId
): Future[Result[seq[PeerId], string]] {.async: (raises: []).} =
  ## Look up providers for a spcific service id

  disco.serviceRoutingTables.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConf.bucketsCount
  )

  let searchTable = disco.serviceRoutingTables.getTable(serviceId).valueOr:
    return err("service table not found for service id: " & $serviceId)

  var found = initHashSet[PeerId]()
  block outer:
    for bucketIdx in 0 ..< searchTable.buckets.len:
      var bucket = searchTable.buckets[bucketIdx]
      if bucket.peers.len == 0:
        continue

      disco.rng.shuffle(bucket.peers)

      let numToQuery = min(disco.discoConf.kLookup, bucket.peers.len)
      for i in 0 ..< numToQuery:
        let peerId = bucket.peers[i].nodeId.toPeerId().valueOr:
          error "cannot convert key to peer id", error
          continue

        let (ads, closerPeers) = (await sendGetAds(disco, peerId, serviceId)).valueOr:
          error "failed to get ads", error
          continue

        for nodeId in closerPeers:
          disco.serviceRoutingTables.insertPeer(serviceId, nodeId.toKey())

        for ad in ads:
          found.incl(ad.data.peerId)

          if found.len >= disco.discoConf.fLookup:
            break outer

  return ok(found.toSeq())

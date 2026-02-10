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

proc new*(T: typedesc[Discoverer]): T =
  T()

proc sendGetAds(
    disco: KademliaDiscovery, peerId: PeerId, serviceId: ServiceId
): Future[Result[(seq[Advertisement], seq[PeerId]), string]] {.async: (raises: []).} =
  ## Send GET_ADS request to a peer

  var ads: seq[Advertisement] = @[]
  var peerIds: seq[PeerId] = @[]

  let addrs = disco.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return ok((ads, peerIds))

  let connRes = catch:
    await disco.switch.dial(peerId, addrs, disco.codec)
  let conn = connRes.valueOr:
    return err("Dialing peer failed: " & error.msg)
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
    return err("Failed to decode get ads message response" & $error)

  # Extract ads from new nested GetAds message structure
  if reply.getAds.isSome():
    let getAdsMsg = reply.getAds.get()
    for adBuf in getAdsMsg.advertisements:
      let ad = Advertisement.decode(adBuf).valueOr:
        debug "Failed to decode advertisement", err = error
        continue

      # Verify signature and peerId match
      if ad.checkValid().isOk():
        # RFC: Verify service advertised matches service_id_hash
        # The advertisement must advertise the requested service
        if ad.advertisesService(serviceId):
          ads.add(ad)
        else:
          debug "Advertisement service mismatch", requested = toHex(serviceId)

  for peer in reply.closerPeers:
    let peerId = PeerId.init(peer.id).valueOr:
      debug "Failed to decode peer id", err = error
      continue

    peerIds.add(peerId)

  return ok((ads, peerIds))

proc lookup*(
    disco: KademliaDiscovery, serviceId: ServiceId
): Future[Result[seq[PeerId], string]] {.async: (raises: []).} =
  ## Look up service providers following RFC LOOKUP algorithm

  disco.serviceRoutingTables.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConf.bucketsCount
  )

  let searchTable = disco.serviceRoutingTables.getTable(serviceId).valueOr:
    return err("Service table not found for service id")

  var found = initHashSet[PeerId]()

  block outer:
    # RFC spec: iterate from far buckets (b_0) to close buckets (b_(m-1))
    # This ensures a gradual search from registrars with fewer shared bits
    # to those with higher number of shared bits with the service ID
    for bucketIdx in 0 ..< searchTable.buckets.len:
      var bucket = searchTable.buckets[bucketIdx]
      if bucket.peers.len == 0:
        continue

      shuffle(disco.rng, bucket.peers)

      let numToQuery = min(disco.discoConf.kLookup, bucket.peers.len)
      for i in 0 ..< numToQuery:
        let peerId = bucket.peers[i].nodeId.toPeerId().valueOr:
          error "Cannot convert key to peer id", error = error
          continue

        let getAdsRes = await sendGetAds(disco, peerId, serviceId)
        let (ads, closerPeers) = getAdsRes.valueOr:
          error "Failed to get ads", err = error
          return

        for nodeId in closerPeers:
          disco.serviceRoutingTables.insertPeer(serviceId, nodeId.toKey())

        for ad in ads:
          found.incl(ad.data.peerId)

          if found.len >= disco.discoConf.fLookup:
            break outer

  return ok(found.toSeq())

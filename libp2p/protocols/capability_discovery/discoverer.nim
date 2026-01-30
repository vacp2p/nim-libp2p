import std/[hashes, tables, sequtils, sets, heapqueue]
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid, multicodec, multiaddress]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ../kademlia/types
import ../kademlia/protobuf as kademlia_protobuf
import ../kademlia/routingtable
import ../kademlia_discovery/types
import ./[types, protobuf]

logScope:
  topics = "kad-disco"

proc new*(T: typedesc[Discoverer]): T =
  T(discTable: initTable[ServiceId, SearchTable]())

proc addServiceInterest*(disco: KademliaDiscovery, serviceId: ServiceId) =
  ## Include this service in the set of services this node is interested in.

  if serviceId in disco.discoverer.discTable:
    return

  var searchTable = SearchTable.new(
    serviceId,
    config = RoutingTableConfig.new(
      replication = disco.config.replication, maxBuckets = disco.discoConf.bucketsCount
    ),
  )

  # Bootstrap from main KadDHT routing table
  for bucket in disco.rtable.buckets:
    for peer in bucket.peers:
      let peerId = peer.nodeId.toPeerId().valueOr:
        continue

      let peerKey = peerId.toKey()

      discard searchTable.insert(peerKey)

  disco.discoverer.discTable[serviceId] = searchTable

proc removeServiceInterest*(discoverer: Discoverer, serviceId: ServiceId) =
  ## Exclude this service from the set of services this node is interested in.

  if serviceId in discoverer.discTable:
    discoverer.discTable.del(serviceId)

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

      var publicKey: PublicKey
      if ad.peerId.extractPublicKey(publicKey):
        if ad.verify(publicKey):
          # RFC: Verify service advertised matches service_id_hash
          # The advertisement must advertise the requested service
          if ad.serviceId == serviceId:
            ads.add(ad)
          else:
            debug "Advertisement service mismatch",
              advertised = bytesToHex(ad.serviceId), requested = bytesToHex(serviceId)

  for peer in reply.closerPeers:
    let peerId = PeerId.init(peer.id).valueOr:
      debug "Failed to decode peer id", err = error
      continue

    peerIds.add(peerId)

  return ok((ads, peerIds))

proc serviceLookup*(
    disco: KademliaDiscovery, serviceId: ServiceId
): Future[Result[seq[PeerId], string]] {.async: (raises: []).} =
  ## Look up service providers following RFC LOOKUP algorithm

  disco.addServiceInterest(serviceId)

  let searchTableRes = catch:
    disco.discoverer.discTable[serviceId]
  var searchTable = searchTableRes.valueOr:
    return err("Cannot find service id in search table: " & searchTableRes.error.msg)

  var found = initHashSet[PeerId]()

  block outer:
    for bucketIdx in countdown(searchTable.buckets.len - 1, 0):
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
          discard searchTable.insert(nodeId.toKey())

        for ad in ads:
          found.incl(ad.peerId)

          if found.len >= disco.discoConf.fLookup:
            break outer

  return ok(found.toSeq())

#TODO the kademlia code already has a bootstrap proc that can do this, lets reuse it
proc refreshSearchTables*(disco: KademliaDiscovery) {.async: (raises: []).} =
  ## Refresh search tables for all services of interest.
  ## This function periodically updates DiscT(service_id_hash) tables
  ## with peers from the main KadDHT routing table.

  # Iterate over all services we're interested in
  for serviceId, searchTable in disco.discoverer.discTable.mpairs:
    # Get peers from main KadDHT routing table
    # For each bucket in the main routing table, add random peers to the search table
    for bucket in disco.rtable.buckets:
      if bucket.peers.len == 0:
        continue

      # Create a mutable copy for shuffling
      var peers = newSeq[NodeEntry](bucket.peers.len)
      for i, peer in bucket.peers:
        peers[i] = peer

      # Shuffle to get random selection
      shuffle(disco.rng, peers)

      # Add up to a few peers from each bucket to the search table
      let numToAdd = min(3, peers.len)
      for i in 0 ..< numToAdd:
        let peer = peers[i]
        # Insert into service-specific search table
        discard searchTable.insert(peer.nodeId)

  # Prune old entries from search tables if they exceed capacity
  # This is a simple implementation - a more sophisticated version would
  # track last seen time and remove stale entries
  for serviceId, searchTable in disco.discoverer.discTable.mpairs:
    # Check if any bucket has too many peers
    for bucket in searchTable.buckets.mitems:
      # Simple pruning: if bucket has too many peers, keep only the most recent ones
      # This is a basic implementation - the RFC doesn't specify exact pruning logic
      if bucket.peers.len > 20: # Arbitrary limit to prevent unbounded growth
        # Keep only the first N peers
        bucket.peers.setLen(20)

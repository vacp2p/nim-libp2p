import std/[hashes, tables, sequtils, sets, heapqueue]
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid, multicodec, multiaddress]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ../kademlia/[types, routingtable, protobuf]
import ./[types, protobuf]

logScope:
  topics = "kad-disco"

proc new*(T: typedesc[Discoverer]): T =
  T(discTable: initTable[ServiceId, SearchTable]())

proc addServiceInterest*(
    discoverer: Discoverer,
    serviceId: ServiceId,
    config: KadDHTConfig,
    discoConf: KademliaDiscoveryConfig,
) =
  ## Include this service in the set of services this node is interested in.

  if serviceId notin discoverer.discTable:
    discoverer.discTable[serviceId] = SearchTable.new(
      serviceId,
      config = RoutingTableConfig.new(
        replication = config.replication, maxBuckets = discoConf.bucketsCount
      ),
    )

proc removeServiceInterest*(discoverer: Discoverer, serviceId: ServiceId) =
  ## Exclude this service from the set of services this node is interested in.

  if serviceId in discoverer.discTable:
    discoverer.discTable.del(serviceId)

proc sendGetAds(
    disco: KademliaDiscovery, peerId: PeerId, serviceId: ServiceId
): Future[(seq[Advertisement], seq[PeerId])] {.async.} =
  ## Send GET_ADS request to a peer
  var ads: seq[Advertisement] = @[]
  var peerIds: seq[PeerId] = @[]

  let addrs = disco.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return (ads, peerIds)

  let conn = await disco.switch.dial(peerId, addrs, ExtendedKademliaDiscoveryCodec)
  defer:
    await conn.close()

  let msg = Message(msgType: MessageType.getAds, key: serviceId)

  try:
    await conn.writeLp(msg.encode().buffer)

    let replyBuf = await conn.readLp(MaxMsgSize)
    let replyRes = Message.decode(replyBuf)

    if replyRes.isErr:
      debug "Failed to decode get-ads response", err = replyRes.error
      return (ads, peerIds)

    let reply = replyRes.get()

    # Decode advertisements
    for adBuf in reply.ads:
      let adRes = Advertisement.decode(adBuf)
      if adRes.isOk:
        let ad = adRes.get()

        # Verify signature
        var publicKey: PublicKey
        if ad.peerId.extractPublicKey(publicKey):
          if ad.verify(publicKey):
            ads.add(ad)

    # Decode closer peers
    for peer in reply.closerPeers:
      let peerIdRes = PeerId.init(peer.id)
      if peerIdRes.isOk:
        peerIds.add(peerIdRes.get())
  except LPStreamError as exc:
    debug "Stream error during get-ads", err = exc.msg

  return (ads, peerIds)

proc serviceLookup*(
    disco: KademliaDiscovery, serviceId: ServiceId
): Future[seq[PeerId]] {.async.} =
  ## Look up service providers following RFC LOOKUP algorithm
  disco.discoverer.addServiceInterest(serviceId, disco.config, disco.discoConf)

  var rtable = disco.discoverer.discTable.getOrDefault(serviceId, nil)
  if rtable.isNil:
    disco.discoverer.addServiceInterest(serviceId, disco.config, disco.discoConf)
    rtable = disco.discoverer.discTable.getOrDefault(serviceId, nil)

  var found = initHashSet[PeerId]()

  block outer:
    for bucketIdx in countdown(disco.discoConf.bucketsCount - 1, 0):
      var bucket = rtable.buckets[bucketIdx]
      if bucket.peers.len == 0:
        continue

      shuffle(disco.rng, bucket.peers)

      let numToQuery = min(disco.discoConf.kLookup, bucket.peers.len)
      for i in 0 ..< numToQuery:
        let peerId = bucket.peers[i].nodeId.toPeerId()
        if peerId.isErr:
          error "cannot convert key to peer id", error = peerId.error
          continue

        let (ads, closer) = await sendGetAds(disco, peerId.get(), serviceId)

        # Add closer peers to routing table
        for nodeId in closer:
          let _ = rtable.insert(nodeId.toKey())

        # Verify and add advertisers to found set
        for ad in ads:
          # Extract and verify public key from peer ID
          var publicKey: PublicKey
          if ad.peerId.extractPublicKey(publicKey):
            if ad.verify(publicKey):
              found.incl(ad.peerId)

          if found.len >= disco.discoConf.fLookup:
            break outer

  return found.toSeq()

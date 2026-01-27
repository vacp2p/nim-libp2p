import std/[hashes, tables, sequtils, sets, heapqueue, times, math, options]
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid, multicodec, multiaddress, routing_record]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ../kademlia/[types, protobuf, routingtable]
import ./[types, iptree, protobuf]

logScope:
  topics = "kad-disco"

proc new*(T: typedesc[Registrar]): T =
  T(
    cache: initOrderedTable[ServiceId, seq[Advertisement]](),
    cacheTimestamps: initTable[Advertisement, int64](),
    ipTree: IpTree.new(),
  )

proc pruneExpiredAds*(registrar: Registrar, advertExpiry: float64) {.raises: [].} =
  ## Remove expired advertisements from cache
  let now = getTime().toUnix()
  var toDelete: seq[tuple[serviceId: ServiceId, ad: Advertisement]] = @[]

  for serviceId, ads in registrar.cache.mpairs:
    var i = 0
    while i < ads.len:
      let ad = ads[i]
      let adTime = registrar.cacheTimestamps.getOrDefault(ad, 0)
      if now - adTime > advertExpiry.int64:
        # Expired - remove from IP tree
        for addr in ad.addrs:
          let ipOpt = addr.getIp()
          if ipOpt.isNone():
            continue
          let ip = ipOpt.unsafeGet()
          try:
            registrar.ipTree.removeIp(ip)
          except ValueError:
            discard
        toDelete.add((serviceId, ad))
        ads.delete(i)
      else:
        inc(i)

  for (serviceId, ad) in toDelete:
    registrar.cacheTimestamps.del(ad)

proc waitingTime*(
    registrar: Registrar,
    discoConf: KademliaDiscoveryConfig,
    advertCacheCap: float64,
    ad: Advertisement,
): float64 {.raises: [].} =
  ## Calculate waiting time for advertisement registration
  let c = registrar.cacheTimestamps.len.float64

  let c_s = registrar.cache.getOrDefault(ad.serviceId, @[]).len.float64

  let occupancy =
    if c >= advertCacheCap:
      100.0 # Cap at high value when full
    else:
      1.0 / pow(1.0 - c / advertCacheCap, discoConf.occupancyExp)

  let serviceSim = c_s / advertCacheCap

  # Extract IP from first multiaddress
  var ipSim = 0.0
  if ad.addrs.len > 0:
    let ipOpt = ad.addrs[0].getIp()
    if ipOpt.isSome():
      try:
        ipSim = registrar.ipTree.ipScore(ipOpt.unsafeGet())
      except ValueError:
        discard

  return
    discoConf.advertExpiry * occupancy * (serviceSim + ipSim + discoConf.safetyParam)

proc getPeers*(
    disco: KademliaDiscovery, serviceId: ServiceId, bucketsCount: int
): seq[Key] =
  ## Get peers closer to the serviceId
  var ltable = RoutingTable.new(
    serviceId,
    config = RoutingTableConfig.new(
      replication = disco.config.replication, maxBuckets = bucketsCount
    ),
  )

  for i in 0 ..< disco.rtable.buckets.len:
    let bucket = disco.rtable.buckets[i]
    for j in 0 ..< bucket.peers.len:
      let nodeId = bucket.peers[j].nodeId
      let _ = ltable.insert(nodeId)

  var found = initHashSet[Key]()

  block outer:
    for bucketIdx in 0 ..< bucketsCount:
      var bucket = ltable.buckets[bucketIdx]
      if bucket.peers.len == 0:
        continue

      shuffle(disco.rng, bucket.peers)

      let nodeId = bucket.peers[0].nodeId
      found.incl(nodeId)

  return found.toSeq()

proc handleGetAds*(
    disco: KademliaDiscovery, conn: Connection, msg: Message
) {.async: (raises: []).} =
  ## Handle GET_ADS request
  let serviceId = msg.key

  # Prune expired ads first
  disco.registrar.pruneExpiredAds(disco.discoConf.advertExpiry)

  # Get cached ads for this service
  var ads: seq[Advertisement]
  for ad in disco.registrar.cache.getOrDefault(serviceId, @[]):
    ads.add(ad)

  # Limit to F_return ads
  let fReturn = min(ads.len, disco.discoConf.fReturn)
  var adBufs: seq[seq[byte]] = @[]
  if ads.len > 0:
    for i in 0 ..< fReturn:
      adBufs.add(ads[i].encode())

  # Get closer peers
  let closerPeerKeys = getPeers(disco, serviceId, disco.discoConf.bucketsCount)

  var closerPeers: seq[Peer] = @[]
  for peerKey in closerPeerKeys:
    let peerIdRes = peerKey.toPeerId()
    if peerIdRes.isOk:
      let peerId = peerIdRes.get()
      let addrs = disco.switch.peerStore[AddressBook][peerId]
      closerPeers.add(
        Peer(
          id: peerId.getBytes(), addrs: addrs, connection: ConnectionType.notConnected
        )
      )

  # Send response
  let writeRes = catch:
    await conn.writeLp(
      Message(msgType: MessageType.getAds, ads: adBufs, closerPeers: closerPeers).encode().buffer
    )
  if writeRes.isErr:
    debug "Failed to send get-ads response", err = writeRes.error.msg

proc handleRegister*(
    disco: KademliaDiscovery, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  ## Handle REGISTER request following RFC algorithm
  # Decode the advertisement
  if msg.ad.isSome():
    let adBuf = msg.ad.get()
    let adRes = Advertisement.decode(adBuf)
    if adRes.isErr:
      # Invalid advertisement, reject
      try:
        await conn.writeLp(
          Message(
            msgType: MessageType.register,
            status: Opt.some(uint32(RegistrationStatus.Rejected.ord)),
            closerPeers: @[],
          ).encode().buffer
        )
      except LPStreamError as exc:
        debug "Failed to send register response", err = exc.msg
      return

    let ad = adRes.get()
    let now = getTime().toUnix()

    # Verify signature
    var publicKey: PublicKey
    if not ad.peerId.extractPublicKey(publicKey):
      # Can't extract public key, reject
      try:
        await conn.writeLp(
          Message(
            msgType: MessageType.register,
            status: Opt.some(uint32(RegistrationStatus.Rejected.ord)),
            closerPeers: @[],
          ).encode().buffer
        )
      except LPStreamError as exc:
        debug "Failed to send register response", err = exc.msg
      return

    if not ad.verify(publicKey):
      # Invalid signature, reject
      try:
        await conn.writeLp(
          Message(
            msgType: MessageType.register,
            status: Opt.some(uint32(RegistrationStatus.Rejected.ord)),
            closerPeers: @[],
          ).encode().buffer
        )
      except LPStreamError as exc:
        debug "Failed to send register response", err = exc.msg
      return

    # Prune expired ads first
    disco.registrar.pruneExpiredAds(disco.discoConf.advertExpiry)

    # Calculate wait time
    let t_wait =
      waitingTime(disco.registrar, disco.discoConf, disco.discoConf.advertCacheCap, ad)

    var t_remaining = t_wait
    var ticket = Ticket(ad: ad, t_init: now, t_mod: now, t_wait_for: 0, signature: @[])

    # Check if ticket provided (retry)
    if msg.ticket.isSome():
      let ticketBuf = msg.ticket.get()
      let ticketRes = Ticket.decode(ticketBuf)
      if ticketRes.isOk:
        let decodedTicket = ticketRes.get()

        # Verify ticket signature with registrar's key
        let registrarKey = disco.switch.peerInfo.privateKey
        let pubKeyRes = registrarKey.getPublicKey()
        if pubKeyRes.isOk:
          let registrarPubKey = pubKeyRes.get()
          if decodedTicket.verify(registrarPubKey):
            # Verify ticket.ad matches current ad
            if decodedTicket.ad.serviceId == ad.serviceId and
                decodedTicket.ad.peerId == ad.peerId:
              # Verify retry within registration window (±1 second)
              let elapsed = now - decodedTicket.t_init
              let delta = disco.discoConf.registerationWindow.seconds.int64

              if abs(elapsed) <= delta + 1:
                # Valid retry, calculate remaining time
                let waitSoFar = float64(now - decodedTicket.t_init)
                t_remaining = t_wait - waitSoFar

    if t_remaining <= 0:
      # Accept the advertisement
      var ads = disco.registrar.cache.getOrDefault(ad.serviceId)
      if ad.serviceId notin disco.registrar.cache:
        ads = @[]
        disco.registrar.cache[ad.serviceId] = ads

      # Check for duplicate
      var isDuplicate = false
      for existingAd in ads:
        if existingAd.peerId == ad.peerId:
          isDuplicate = true
          # Update timestamp
          disco.registrar.cacheTimestamps[existingAd] = now
          break

      if not isDuplicate:
        ads.add(ad)
        disco.registrar.cacheTimestamps[ad] = now

        # Update IP tree
        for addr in ad.addrs:
          let ipOpt = addr.getIp()
          if ipOpt.isSome():
            try:
              disco.registrar.ipTree.insertIp(ipOpt.unsafeGet())
            except ValueError:
              discard

      # Send Confirmed response
      try:
        await conn.writeLp(
          Message(
            msgType: MessageType.register,
            status: Opt.some(uint32(RegistrationStatus.Confirmed.ord)),
            closerPeers: @[],
          ).encode().buffer
        )
      except LPStreamError as exc:
        debug "Failed to send register response", err = exc.msg
    else:
      # Send Wait response with ticket
      ticket.t_wait_for = min(disco.discoConf.advertExpiry.uint32, t_remaining.uint32)
      ticket.t_mod = now

      # Sign ticket with registrar's key
      let registrarKey = disco.switch.peerInfo.privateKey
      let signRes = ticket.sign(registrarKey)
      if signRes.isOk:
        try:
          await conn.writeLp(
            Message(
              msgType: MessageType.register,
              status: Opt.some(uint32(RegistrationStatus.Wait.ord)),
              ticket: Opt.some(ticket.encode()),
              closerPeers: @[],
            ).encode().buffer
          )
        except LPStreamError as exc:
          debug "Failed to send register response", err = exc.msg
      else:
        # Signing failed, reject
        try:
          await conn.writeLp(
            Message(
              msgType: MessageType.register,
              status: Opt.some(uint32(RegistrationStatus.Rejected.ord)),
              closerPeers: @[],
            ).encode().buffer
          )
        except LPStreamError as exc:
          debug "Failed to send register response", err = exc.msg
  else:
    # No ad provided, reject
    try:
      await conn.writeLp(
        Message(
          msgType: MessageType.register,
          status: Opt.some(uint32(RegistrationStatus.Rejected.ord)),
          closerPeers: @[],
        ).encode().buffer
      )
    except LPStreamError as exc:
      debug "Failed to send register response", err = exc.msg

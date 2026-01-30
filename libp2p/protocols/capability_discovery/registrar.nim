import std/[hashes, tables, sequtils, sets, heapqueue, times, math, options]
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid, multicodec, multiaddress, routing_record]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ../kademlia/types
import ../kademlia/protobuf as kademlia_protobuf
import ../kademlia/routingtable
import ../kademlia_discovery/types
import ./[types, iptree, protobuf]

logScope:
  topics = "kad-disco"

proc new*(T: typedesc[Registrar]): T =
  T(
    cache: initOrderedTable[ServiceId, seq[Advertisement]](),
    cacheTimestamps: initTable[Advertisement, int64](),
    ipTree: IpTree.new(),
    boundService: initTable[ServiceId, float64](),
    timestampService: initTable[ServiceId, int64](),
    boundIp: initTable[string, float64](),
    timestampIp: initTable[string, int64](),
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
          let ip = addr.getIp()
          if ip.isSome():
            discard registrar.ipTree.removeIp(ip.unsafeGet())
              # Silently ignore IPv6 or non-existent IPs during cleanup
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
    now: int64,
): float64 {.raises: [].} =
  ## Calculate waiting time for advertisement registration with lower bound enforcement
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
  var ipKey = ""
  if ad.addrs.len > 0:
    let ipOpt = ad.addrs[0].getIp()
    if ipOpt.isSome():
      let ip = ipOpt.unsafeGet()
      let scoreRes = registrar.ipTree.ipScore(ip)
      if scoreRes.isOk():
        ipSim = scoreRes.get()
      ipKey = $ip

  # Calculate initial waiting time
  var w =
    discoConf.advertExpiry * occupancy * (serviceSim + ipSim + discoConf.safetyParam)

  # Enforce service ID lower bound (RFC section: Lower Bound Enforcement)
  # w_s = max(w_s, bound(service_id_hash) - (now - timestamp(service_id_hash)))
  if ad.serviceId in registrar.timestampService:
    let elapsedService =
      float64(now - registrar.timestampService.getOrDefault(ad.serviceId, 0))
    let boundServiceVal = registrar.boundService.getOrDefault(ad.serviceId, 0.0)
    let serviceLowerBound = boundServiceVal - elapsedService
    if serviceLowerBound > w:
      w = serviceLowerBound

  # Enforce IP lower bound
  # w_ip = max(w_s, bound(IP) - (now - timestamp(IP)))
  if ipKey != "" and ipKey in registrar.timestampIp:
    let elapsedIp = float64(now - registrar.timestampIp.getOrDefault(ipKey, 0))
    let boundIpVal = registrar.boundIp.getOrDefault(ipKey, 0.0)
    let ipLowerBound = boundIpVal - elapsedIp
    if ipLowerBound > w:
      w = ipLowerBound

  return w

proc updateLowerBounds*(
    registrar: Registrar,
    serviceId: ServiceId,
    ad: Advertisement,
    w: float64,
    now: int64,
) {.raises: [].} =
  ## Update lower bound state for service and IP (RFC section: Lower Bound Enforcement)
  # Update service lower bound if w exceeds current lower bound
  let elapsedService =
    float64(now - registrar.timestampService.getOrDefault(serviceId, 0))

  let boundServiceVal = registrar.boundService.getOrDefault(serviceId, 0.0)
  if w > (boundServiceVal - elapsedService):
    registrar.boundService[serviceId] = w + float64(now)
    registrar.timestampService[serviceId] = now

  # Update IP lower bound if w exceeds current lower bound
  var ipKey = ""
  if ad.addrs.len > 0:
    let ipOpt = ad.addrs[0].getIp()
    if ipOpt.isSome():
      ipKey = $ipOpt.unsafeGet()

  if ipKey != "":
    let elapsedIp = float64(now - registrar.timestampIp.getOrDefault(ipKey, 0))

    let boundIpVal = registrar.boundIp.getOrDefault(ipKey, 0.0)
    if w > (boundIpVal - elapsedIp):
      registrar.boundIp[ipKey] = w + float64(now)
      registrar.timestampIp[ipKey] = now

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

proc sendRegisterReject*(
    conn: Connection, closerPeers: seq[Peer] = @[]
) {.async: (raises: []).} =
  ## Helper to send a rejection response
  let writeRes = catch:
    await conn.writeLp(
      Message(
        msgType: MessageType.register,
        register: Opt.some(
          RegisterMessage(
            advertisement: @[],
            status: Opt.some(kademlia_protobuf.RegistrationStatus.Rejected),
            ticket: Opt.none(TicketMessage),
          )
        ),
        closerPeers: closerPeers,
      ).encode().buffer
    )
  if writeRes.isErr:
    debug "Failed to send register response", err = writeRes.error.msg

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
    let peerId = peerKey.toPeerId().valueOr:
      debug "Failed to convert key to peer id", error = error
      continue
    let addrs = disco.switch.peerStore[AddressBook][peerId]
    closerPeers.add(
      Peer(id: peerId.getBytes(), addrs: addrs, connection: ConnectionType.notConnected)
    )

  # Send response with new nested GetAds message structure
  let writeRes = catch:
    await conn.writeLp(
      Message(
        msgType: MessageType.getAds,
        getAds: Opt.some(GetAdsMessage(advertisements: adBufs)),
        closerPeers: closerPeers,
      ).encode().buffer
    )
  if writeRes.isErr:
    debug "Failed to send get-ads response", err = writeRes.error.msg

proc handleRegister*(
    disco: KademliaDiscovery, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  ## Handle REGISTER request following RFC algorithm

  # Get closer peers for responses (RFC requires closerPeers in all responses)
  let closerPeerKeys = getPeers(disco, msg.key, disco.discoConf.bucketsCount)
  var closerPeers: seq[Peer] = @[]
  for peerKey in closerPeerKeys:
    let peerId = peerKey.toPeerId().valueOr:
      continue
    let addrs = disco.switch.peerStore[AddressBook][peerId]
    closerPeers.add(
      Peer(id: peerId.getBytes(), addrs: addrs, connection: ConnectionType.notConnected)
    )

  proc sendReject(closerPeers: seq[Peer] = @[]) {.async: (raises: []).} =
    ## Send rejection response - helper using catch:
    let writeRes = catch:
      await conn.writeLp(
        Message(
          msgType: MessageType.register,
          register: Opt.some(
            RegisterMessage(
              advertisement: @[],
              status: Opt.some(kademlia_protobuf.RegistrationStatus.Rejected),
              ticket: Opt.none(TicketMessage),
            )
          ),
          closerPeers: closerPeers,
        ).encode().buffer
      )
    if writeRes.isErr:
      debug "Failed to send register response", err = writeRes.error.msg

  # Decode the advertisement from new nested message structure
  if msg.register.isSome():
    let regMsg = msg.register.get()
    let adBuf = regMsg.advertisement

    if adBuf.len == 0:
      # No ad provided, reject
      await sendReject(closerPeers)
      return

    let ad = Advertisement.decode(adBuf).valueOr:
      # Invalid advertisement, reject
      debug "Invalid advertisement received", err = error
      await sendReject(closerPeers)
      return

    let now = getTime().toUnix()

    # Verify signature
    var publicKey: PublicKey
    if not ad.peerId.extractPublicKey(publicKey):
      # Can't extract public key, reject
      debug "Failed to extract public key from peer id"
      await sendReject(closerPeers)
      return

    if not ad.verify(publicKey):
      # Invalid signature, reject
      debug "Invalid advertisement signature"
      await sendReject(closerPeers)
      return

    # Prune expired ads first
    disco.registrar.pruneExpiredAds(disco.discoConf.advertExpiry)

    # Calculate wait time with lower bound enforcement
    let t_wait = waitingTime(
      disco.registrar, disco.discoConf, disco.discoConf.advertCacheCap, ad, now
    )

    # Update lower bounds for service and IP (RFC section: Lower Bound Enforcement)
    disco.registrar.updateLowerBounds(ad.serviceId, ad, t_wait, now)

    var t_remaining = t_wait
    var ticket = Ticket(ad: ad, t_init: now, t_mod: now, t_wait_for: 0, signature: @[])

    # Check if ticket provided (retry)
    if regMsg.ticket.isSome():
      let ticketMsg = regMsg.ticket.get()

      # Convert TicketMessage to Ticket for verification
      let ticketAdRes = Advertisement.decode(ticketMsg.advertisement)
      if ticketAdRes.isOk():
        let ticketAd = ticketAdRes.get()

        # Create Ticket from TicketMessage for verification
        let ticketVal = Ticket(
          ad: ticketAd,
          t_init: ticketMsg.tInit.int64,
          t_mod: ticketMsg.tMod.int64,
          t_wait_for: ticketMsg.tWaitFor,
          signature: ticketMsg.signature,
        )

        # Verify ticket signature with registrar's key
        let pubKeyRes = disco.switch.peerInfo.privateKey.getPublicKey()
        if pubKeyRes.isOk():
          let registrarPubKey = pubKeyRes.get()
          if ticketVal.verify(registrarPubKey):
            # Verify ticket.ad matches current ad
            if ticketVal.ad.serviceId == ad.serviceId and
                ticketVal.ad.peerId == ad.peerId:
              # Verify retry within registration window (±1 second)
              let elapsed = now - ticketVal.t_init
              let delta = disco.discoConf.registerationWindow.seconds.int64

              if abs(elapsed) <= delta + 1:
                # Valid retry, calculate remaining time
                let waitSoFar = float64(now - ticketVal.t_init)
                t_remaining = t_wait - waitSoFar
        else:
          debug "Failed to get registrar public key", err = pubKeyRes.error

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
          let ip = addr.getIp()
          if ip.isSome():
            discard disco.registrar.ipTree.insertIp(ip.unsafeGet())

      # Send Confirmed response with closerPeers
      let writeRes = catch:
        await conn.writeLp(
          Message(
            msgType: MessageType.register,
            register: Opt.some(
              RegisterMessage(
                advertisement: @[],
                status: Opt.some(kademlia_protobuf.RegistrationStatus.Confirmed),
                ticket: Opt.none(TicketMessage),
              )
            ),
            closerPeers: closerPeers,
          ).encode().buffer
        )
      if writeRes.isErr:
        debug "Failed to send register response", err = writeRes.error.msg
    else:
      # Send Wait response with ticket
      ticket.t_wait_for = min(disco.discoConf.advertExpiry.uint32, t_remaining.uint32)
      ticket.t_mod = now

      # Sign ticket with registrar's key
      let signRes = ticket.sign(disco.switch.peerInfo.privateKey)
      if signRes.isOk:
        # Convert Ticket to TicketMessage for response
        let ticketMsg = TicketMessage(
          advertisement: ticket.ad.encode(),
          tInit: ticket.t_init.uint64,
          tMod: ticket.t_mod.uint64,
          tWaitFor: ticket.t_wait_for,
          signature: ticket.signature,
        )

        let writeRes = catch:
          await conn.writeLp(
            Message(
              msgType: MessageType.register,
              register: Opt.some(
                RegisterMessage(
                  advertisement: @[],
                  status: Opt.some(kademlia_protobuf.RegistrationStatus.Wait),
                  ticket: Opt.some(ticketMsg),
                )
              ),
              closerPeers: closerPeers,
            ).encode().buffer
          )
        if writeRes.isErr:
          debug "Failed to send register response", err = writeRes.error.msg
      else:
        # Signing failed, reject
        debug "Failed to sign ticket", err = signRes.error
        await sendReject(closerPeers)
  else:
    # No register message provided, reject
    await sendReject(closerPeers)

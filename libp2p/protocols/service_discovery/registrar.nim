# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sets, heapqueue, times, math]
import chronos, chronicles, results
import
  ../../[
    peerid, switch, multihash, cid, multicodec, multiaddress, routing_record,
    extended_peer_record,
  ]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ../kademlia
import ../kademlia/types
import ../kademlia/protobuf as kademlia_protobuf
import ../kademlia/routingtable
import ../kademlia_discovery/types
import ./[types, iptree, serviceroutingtables, service_discovery_metrics]

logScope:
  topics = "service-disco registrar"

proc updateRegistrarMetrics(registrar: Registrar) {.raises: [].} =
  var totalAds = 0
  for ads in registrar.cache.values:
    totalAds += ads.len
  cd_registrar_cache_ads.set(totalAds.float64)
  cd_registrar_cache_services.set(registrar.cache.len.float64)
  cd_iptree_unique_ips.set(registrar.ipTree.root.counter.float64)

proc new*(T: typedesc[Registrar]): T =
  T(
    cache: initOrderedTable[ServiceId, seq[Advertisement]](),
    cacheTimestamps: initTable[AdvertisementKey, uint64](),
    ipTree: IpTree.new(),
    boundService: initTable[ServiceId, float64](),
    timestampService: initTable[ServiceId, uint64](),
    boundIp: initTable[string, float64](),
    timestampIp: initTable[string, uint64](),
  )

proc pruneExpiredAds*(
    registrar: Registrar, advertExpiry: uint64
) {.async: (raises: []).} =
  await registrar.lock.withLock:
    let now = getTime().toUnix().uint64
    var toDelete: seq[tuple[serviceId: ServiceId, ad: Advertisement]] = @[]

    for serviceId, ads in registrar.cache.mpairs:
      var i = 0
      while i < ads.len:
        let ad = ads[i]
        let adKey = ad.toAdvertisementKey()
        let adTime = registrar.cacheTimestamps.getOrDefault(adKey, 0)

        if now - adTime > advertExpiry:
          registrar.ipTree.removeAd(ad).isOkOr:
            debug "failed to remove ad from IP tree during prune", error
          toDelete.add((serviceId, ad))
          ads.delete(i)
        else:
          inc(i)

    for (_, ad) in toDelete:
      registrar.cacheTimestamps.del(ad.toAdvertisementKey())

    if toDelete.len > 0:
      cd_registrar_ads_expired.inc(toDelete.len.float64)
      registrar.updateRegistrarMetrics()

    var expiredServices: seq[ServiceId] = @[]
    for sid, ts in registrar.timestampService:
      if now - ts > advertExpiry:
        expiredServices.add(sid)
    for sid in expiredServices:
      registrar.boundService.del(sid)
      registrar.timestampService.del(sid)

    var expiredIps: seq[string] = @[]
    for ip, ts in registrar.timestampIp:
      if now - ts > advertExpiry:
        expiredIps.add(ip)
    for ip in expiredIps:
      registrar.boundIp.del(ip)
      registrar.timestampIp.del(ip)

proc waitingTime*(
    registrar: Registrar,
    discoConf: KademliaDiscoveryConfig,
    ad: Advertisement,
    advertCacheCap: uint64,
    serviceId: ServiceId,
    now: uint64,
): Future[float64] {.async: (raises: []).} =
  await registrar.lock.withLock:
    let c = registrar.cacheTimestamps.len.uint64
    let c_s = registrar.cache.getOrDefault(serviceId, @[]).len

    let occupancy: float64 =
      if c >= advertCacheCap:
        100.0
      else:
        1.0 / pow(1.0 - c.float64 / advertCacheCap.float64, discoConf.occupancyExp)

    let serviceSim: float64 = c_s.float64 / advertCacheCap.float64
    let ipSim = registrar.ipTree.adScore(ad)

    var w: float64 =
      discoConf.advertExpiry * occupancy * (serviceSim + ipSim + discoConf.safetyParam)

    if serviceId in registrar.timestampService:
      let elapsedService = now - registrar.timestampService.getOrDefault(serviceId, 0)
      let boundServiceVal = registrar.boundService.getOrDefault(serviceId, 0.0)
      let serviceLowerBound = boundServiceVal - elapsedService.float64
      if serviceLowerBound > w:
        w = serviceLowerBound

    for addressInfo in ad.data.addresses:
      let ip = addressInfo.address.getIp().valueOr:
        continue

      let ipKey = $ip
      if ipKey in registrar.timestampIp:
        let elapsedIp = now - registrar.timestampIp.getOrDefault(ipKey, 0)
        let boundIpVal = registrar.boundIp.getOrDefault(ipKey, 0.0)
        let ipLowerBound = boundIpVal - elapsedIp.float64
        if ipLowerBound > w:
          w = ipLowerBound

    return max(0.0, w)

proc updateLowerBounds*(
    registrar: Registrar,
    serviceId: ServiceId,
    ad: Advertisement,
    w: float64,
    now: uint64,
) {.async: (raises: []).} =
  await registrar.lock.withLock:
    let elapsedService = now - registrar.timestampService.getOrDefault(serviceId, 0)
    let boundServiceVal = registrar.boundService.getOrDefault(serviceId, 0.0)

    if w > boundServiceVal - elapsedService.float64:
      registrar.boundService[serviceId] = w + now.float64
      registrar.timestampService[serviceId] = now

    for addressInfo in ad.data.addresses:
      let ip = addressInfo.address.getIp().valueOr:
        continue

      let ipKey = $ip
      let elapsedIp = float64(now - registrar.timestampIp.getOrDefault(ipKey, 0))
      let boundIpVal = registrar.boundIp.getOrDefault(ipKey, 0.0)

      if w > (boundIpVal - elapsedIp):
        registrar.boundIp[ipKey] = w + float64(now)
        registrar.timestampIp[ipKey] = now

proc getRegistrarCloserPeers*(
    disco: KademliaDiscovery, serviceId: ServiceId, count: int
): seq[Peer] {.raises: [].} =
  ## Get closer peers from registrar table for a service.
  ## Falls back to main DHT if table is empty or not found.

  var closerPeerKeys: seq[Key] = @[]
  block thisBlock:
    if disco.serviceRoutingTables.hasService(serviceId):
      let regTable = disco.serviceRoutingTables.getTable(serviceId).valueOr:
        break thisBlock

      for bucket in regTable.buckets:
        let closerPeer = bucket.randomPeerInBucket(disco.rng).valueOr:
          continue
        closerPeerKeys.add(closerPeer)

  if closerPeerKeys.len == 0:
    closerPeerKeys = disco.rtable.findClosest(serviceId, count)

  var closerPeers: seq[Peer] = @[]
  for peerKey in closerPeerKeys:
    let peerId = peerKey.toPeerId().valueOr:
      debug "failed to convert key to peer id", error
      continue

    let addrs = disco.switch.peerStore[AddressBook][peerId]

    closerPeers.add(
      Peer(id: peerId.getBytes(), addrs: addrs, connection: ConnectionType.notConnected)
    )

  return closerPeers

proc sendRegisterResponse*(
    conn: Connection,
    status: kademlia_protobuf.RegistrationStatus,
    closerPeers: seq[Peer],
    ticket: Opt[Ticket] = Opt.none(Ticket),
) {.async: (raises: []).} =
  ## Sender for REGISTER message responses

  let msg = Message(
    msgType: MessageType.register,
    register: Opt.some(
      RegisterMessage(advertisement: @[], status: Opt.some(status), ticket: ticket)
    ),
    closerPeers: closerPeers,
  )
  let bytes = msg.encode().buffer

  let writeRes = catch:
    await conn.writeLp(bytes)
  if writeRes.isErr:
    error "failed to send register response", err = writeRes.error.msg
    return

proc sendRegisterReject*(
    conn: Connection, closerPeers: seq[Peer] = @[]
) {.async: (raises: []).} =
  await conn.sendRegisterResponse(
    kademlia_protobuf.RegistrationStatus.Rejected, closerPeers
  )

proc validateRegisterMessage*(regMsg: RegisterMessage): Opt[Advertisement] =
  ## Validate register message and decode/verify advertisement
  ## Returns none if invalid.

  if regMsg.advertisement.len == 0:
    return Opt.none(Advertisement)

  let ad = Advertisement.decode(regMsg.advertisement).valueOr:
    error "invalid advertisement received", error
    return Opt.none(Advertisement)

  return Opt.some(ad)

proc processRetryTicket*(
    disco: KademliaDiscovery,
    regMsg: RegisterMessage,
    ad: Advertisement,
    t_wait: float64,
    now: uint64,
): float64 {.raises: [].} =
  ## Process retry ticket if provided
  ## Returns remaining wait time (or t_wait if no valid ticket)

  let ticketMsg = regMsg.ticket.valueOr:
    return t_wait

  # Compare ticket.ad bytes directly with regMsg.advertisement bytes
  if ticketMsg.advertisement != regMsg.advertisement:
    return t_wait

  # Verify ticket signature with registrar's key
  let registrarPubKey = disco.switch.peerInfo.privateKey.getPublicKey().valueOr:
    error "Failed to get registrar public key", error
    return t_wait

  if not ticketMsg.verify(registrarPubKey):
    return t_wait

  let windowStart = ticketMsg.tMod + ticketMsg.tWaitFor
  let delta = disco.discoConf.registrationWindow.seconds.uint64
  let windowEnd = windowStart + delta

  if now >= windowStart and now <= windowEnd:
    # Valid retry, calculate remaining time using accumulated wait
    # from original t_init
    let totalWaitSoFar = now - ticketMsg.tInit
    return t_wait - totalWaitSoFar.float64

  return t_wait

proc acceptAdvertisement*(
    disco: KademliaDiscovery,
    serviceId: ServiceId,
    ad: Advertisement,
    now: uint64,
    closerPeers: seq[Peer],
    conn: Connection,
) {.async: (raises: []).} =
  # These may also need locking internally (see note below)
  discard await disco.serviceRoutingTables.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConf.bucketsCount,
    Interest,
  )

  let peerKey = ad.data.peerId.toKey()
  await disco.serviceRoutingTables.insertPeer(serviceId, peerKey)

  var shouldUpdateMetrics = false

  await disco.registrar.lock.withLock:
    var ads = disco.registrar.cache.getOrDefault(serviceId)

    var replaced = false
    var isDuplicate = false

    for i in 0 ..< ads.len:
      if ads[i].data.peerId == ad.data.peerId:
        if ads[i].data.seqNo == ad.data.seqNo:
          isDuplicate = true
          disco.registrar.cacheTimestamps[ads[i].toAdvertisementKey()] = now
        elif ad.data.seqNo > ads[i].data.seqNo:
          disco.registrar.ipTree.removeAd(ads[i]).isOkOr:
            debug "failed to remove ad from IP tree", error
          disco.registrar.cacheTimestamps.del(ads[i].toAdvertisementKey())

          ads[i] = ad

          disco.registrar.cacheTimestamps[ad.toAdvertisementKey()] = now
          disco.registrar.ipTree.insertAd(ad).isOkOr:
            debug "failed to insert ad into IP tree", error

          replaced = true
          shouldUpdateMetrics = true
        else:
          isDuplicate = true
        break

    if not isDuplicate and not replaced:
      if disco.registrar.cacheTimestamps.len.uint64 >=
          disco.discoConf.advertCacheCap.uint64:
        var oldestKey: AdvertisementKey
        var oldestTime = high(uint64)
        for k, t in disco.registrar.cacheTimestamps:
          if t < oldestTime:
            oldestTime = t
            oldestKey = k
        var evictSid: ServiceId
        var evictIdx = -1
        for sid, sads in disco.registrar.cache:
          for i in 0 ..< sads.len:
            if sads[i].toAdvertisementKey() == oldestKey:
              evictSid = sid
              evictIdx = i
              break
          if evictIdx >= 0:
            break
        if evictIdx >= 0:
          var evictAds = disco.registrar.cache[evictSid]
          disco.registrar.ipTree.removeAd(evictAds[evictIdx]).isOkOr:
            debug "failed to remove evicted ad from IP tree", error
          disco.registrar.cacheTimestamps.del(oldestKey)
          evictAds.delete(evictIdx)
          disco.registrar.cache[evictSid] = evictAds
          if evictSid == serviceId:
            ads = evictAds
        shouldUpdateMetrics = true

      ads.add(ad)
      let adKey = ad.toAdvertisementKey()
      disco.registrar.cacheTimestamps[adKey] = now
      disco.registrar.ipTree.insertAd(ad).isOkOr:
        debug "failed to insert ad into IP tree", error
      shouldUpdateMetrics = true

    disco.registrar.cache[serviceId] = ads

    if shouldUpdateMetrics:
      disco.registrar.updateRegistrarMetrics()

  await conn.sendRegisterResponse(
    kademlia_protobuf.RegistrationStatus.Confirmed, closerPeers
  )

proc waitOrRejectAdvertisement*(
    closerPeers: seq[Peer],
    conn: Connection,
    t_remaining: float64,
    ticket: Ticket,
    disco: KademliaDiscovery,
) {.async: (raises: []).} =
  ## Send Wait response with ticket or Rejected response

  var ticket = ticket

  ticket.tWaitFor = min(disco.discoConf.advertExpiry.uint32, t_remaining.uint32)
  ticket.tMod = getTime().toUnix().uint64

  ticket.sign(disco.switch.peerInfo.privateKey).isOkOr:
    error "failed to sign ticket", error
    await conn.sendRegisterReject(closerPeers)
    return

  await conn.sendRegisterResponse(
    kademlia_protobuf.RegistrationStatus.Wait, closerPeers, Opt.some(ticket)
  )

proc handleGetAds*(
    disco: KademliaDiscovery, conn: Connection, msg: Message
) {.async: (raises: []).} =
  ## Handle GET_ADS request

  cd_messages_received.inc(labelValues = [$MessageType.getAds])

  let serviceId = msg.key

  disco.registrar.pruneExpiredAds(disco.discoConf.advertExpiry.uint64)

  var ads: seq[Advertisement]
  for ad in disco.registrar.cache.getOrDefault(serviceId, @[]):
    ads.add(ad)

  var adBufs: seq[seq[byte]] = @[]
  for ad in ads:
    let encodedAd = ad.encode().valueOr:
      error "failed to encode ads", error
      continue

    adBufs.add(encodedAd)

  disco.rng.shuffle(adBufs)
  let fReturn = min(adBufs.len, disco.discoConf.fReturn)
  adBufs.setLen(fReturn)

  let closerPeers =
    disco.getRegistrarCloserPeers(serviceId, disco.discoConf.bucketsCount)

  let msg = Message(
    msgType: MessageType.getAds,
    getAds: Opt.some(GetAdsMessage(advertisements: adBufs)),
    closerPeers: closerPeers,
  )
  let bytes = msg.encode().buffer

  let writeRes = catch:
    await conn.writeLp(bytes)
  if writeRes.isErr:
    error "failed to send get-ads response", error = writeRes.error.msg
    return

proc handleRegister*(
    disco: KademliaDiscovery, conn: Connection, msg: Message
) {.async: (raises: []).} =
  cd_messages_received.inc(labelValues = [$MessageType.register])

  let serviceId = msg.key

  let closerPeers =
    disco.getRegistrarCloserPeers(serviceId, disco.discoConf.bucketsCount)

  let regMsg = msg.register.valueOr:
    cd_register_requests.inc(labelValues = [$kademlia_protobuf.Rejected])
    await conn.sendRegisterReject(closerPeers)
    return

  let ad = validateRegisterMessage(regMsg).valueOr:
    cd_register_requests.inc(labelValues = [$kademlia_protobuf.Rejected])
    await conn.sendRegisterReject(closerPeers)
    return

  let now = getTime().toUnix().uint64

  var t_wait: float64
  var t_remaining: float64
  var acceptNow: bool

  # --- ATOMIC DECISION BLOCK ---
  await disco.registrar.lock.withLock:
    # inline prune (no await!)
    let expiry = disco.discoConf.advertExpiry.uint64
    var toDelete: seq[tuple[serviceId: ServiceId, ad: Advertisement]] = @[]

    for sid, ads in disco.registrar.cache.mpairs:
      var i = 0
      while i < ads.len:
        let ad2 = ads[i]
        let key = ad2.toAdvertisementKey()
        let ts = disco.registrar.cacheTimestamps.getOrDefault(key, 0)

        if now - ts > expiry:
          disco.registrar.ipTree.removeAd(ad2).isOkOr:
            debug "failed to remove ad from IP tree during prune", error
          toDelete.add((sid, ad2))
          ads.delete(i)
        else:
          inc(i)

    for (_, ad2) in toDelete:
      disco.registrar.cacheTimestamps.del(ad2.toAdvertisementKey())

    if toDelete.len > 0:
      cd_registrar_ads_expired.inc(toDelete.len.float64)
      disco.registrar.updateRegistrarMetrics()

    var expiredServices: seq[ServiceId] = @[]
    for sid, ts in disco.registrar.timestampService:
      if now - ts > expiry:
        expiredServices.add(sid)
    for sid in expiredServices:
      disco.registrar.boundService.del(sid)
      disco.registrar.timestampService.del(sid)

    var expiredIps: seq[string] = @[]
    for ip, ts in disco.registrar.timestampIp:
      if now - ts > expiry:
        expiredIps.add(ip)
    for ip in expiredIps:
      disco.registrar.boundIp.del(ip)
      disco.registrar.timestampIp.del(ip)

    # compute waiting time (inline, no await)
    let c = disco.registrar.cacheTimestamps.len.uint64
    let c_s = disco.registrar.cache.getOrDefault(serviceId, @[]).len

    let occupancy =
      if c >= disco.discoConf.advertCacheCap.uint64:
        100.0
      else:
        1.0 /
          pow(
            1.0 - c.float64 / disco.discoConf.advertCacheCap.float64,
            disco.discoConf.occupancyExp,
          )

    let serviceSim = c_s.float64 / disco.discoConf.advertCacheCap.float64
    let ipSim = disco.registrar.ipTree.adScore(ad)

    t_wait =
      disco.discoConf.advertExpiry * occupancy *
      (serviceSim + ipSim + disco.discoConf.safetyParam)

    # lower bounds update (inline)
    let elapsedService =
      now - disco.registrar.timestampService.getOrDefault(serviceId, 0)

    let boundServiceVal = disco.registrar.boundService.getOrDefault(serviceId, 0.0)

    if t_wait > boundServiceVal - elapsedService.float64:
      disco.registrar.boundService[serviceId] = t_wait + now.float64
      disco.registrar.timestampService[serviceId] = now

    # retry logic (pure, no shared mutation)
    t_remaining = disco.processRetryTicket(regMsg, ad, t_wait, now)

    acceptNow = t_remaining <= 0
  # --- END LOCK ---

  if acceptNow:
    cd_register_requests.inc(labelValues = [$kademlia_protobuf.Confirmed])
    await disco.acceptAdvertisement(serviceId, ad, now, closerPeers, conn)
    return

  var init = now
  if regMsg.ticket.isSome:
    init = regMsg.ticket.get().tInit

  let ticket = Ticket(
    advertisement: regMsg.advertisement,
    tInit: init,
    tMod: now,
    tWaitFor: 0,
    signature: @[],
  )

  cd_register_requests.inc(labelValues = [$kademlia_protobuf.Wait])
  await waitOrRejectAdvertisement(closerPeers, conn, t_remaining, ticket, disco)

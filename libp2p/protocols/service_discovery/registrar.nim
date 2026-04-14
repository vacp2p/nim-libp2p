# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, math, times, sets]
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
import ../kademlia/routing_table
import ./[types, service_routing_tables, service_discovery_metrics]

export types, service_routing_tables

logScope:
  topics = "service-disco registrar"

proc updateRegistrarMetrics(registrar: Registrar) {.raises: [].} =
  cd_registrar_cache_ads.set(registrar.cacheTimestamps.len.float64)
  cd_registrar_cache_services.set(registrar.cache.len.float64)
  cd_iptree_unique_ips.set(registrar.ipTree.root.counter.float64)

proc adScore*(ipTree: IpTree, ad: Advertisement): float64 {.raises: [].} =
  ## Return the max score for this advertisment

  var maxScore = 0.0
  for addressInfo in ad.data.addresses:
    let multiAddr = addressInfo.address
    let ip = multiAddr.getIp().valueOr:
      continue

    let score = ipTree.ipScore(ip)
    if score > maxScore:
      maxScore = score

  return maxScore

proc insertAd*(ipTree: IpTree, ad: Advertisement) {.raises: [].} =
  for addressInfo in ad.data.addresses:
    let multiAddr = addressInfo.address
    let ip = multiAddr.getIp().valueOr:
      continue
    if ip.family != IpAddressFamily.IPv4:
      continue
    ipTree.insertIp(ip)

proc removeAd*(ipTree: IpTree, ad: Advertisement) {.raises: [].} =
  for addressInfo in ad.data.addresses:
    let multiAddr = addressInfo.address
    let ip = multiAddr.getIp().valueOr:
      continue
    if ip.family != IpAddressFamily.IPv4:
      continue
    ipTree.removeIp(ip)

proc pruneExpiredAds*(
    registrar: Registrar, advertExpiry: uint64
) {.async: (raises: [CancelledError]).} =
  await registrar.lock.acquire()
  try:
    let now = getTime().toUnix().uint64
    var toDelete: seq[tuple[serviceId: ServiceId, ad: Advertisement]] = @[]

    for serviceId, ads in registrar.cache.mpairs:
      var i = 0
      while i < ads.len:
        let ad = ads[i]
        let adKey = ad.toAdvertisementKey()
        let adTime = registrar.cacheTimestamps.getOrDefault(adKey, 0)

        if now - adTime > advertExpiry:
          registrar.ipTree.removeAd(ad)
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

    var expiredNonces: seq[seq[byte]] = @[]
    for nonce, exp in registrar.usedNonces:
      if now > exp:
        expiredNonces.add(nonce)
    for nonce in expiredNonces:
      registrar.usedNonces.del(nonce)
  finally:
    try:
      registrar.lock.release()
    except AsyncLockError as exc:
      raiseAssert exc.msg

proc waitingTime*(
    registrar: Registrar,
    discoConfig: ServiceDiscoveryConfig,
    ad: Advertisement,
    advertCacheCap: uint64,
    serviceId: ServiceId,
    now: uint64,
): Future[float64] {.async: (raises: [CancelledError]).} =
  await registrar.lock.acquire()
  try:
    let c = registrar.cacheTimestamps.len.uint64
    let c_s = registrar.cache.getOrDefault(serviceId, @[]).len

    let occupancy: float64 =
      if c >= advertCacheCap:
        100.0
      else:
        1.0 / pow(1.0 - c.float64 / advertCacheCap.float64, discoConfig.occupancyExp)

    let serviceSim: float64 = c_s.float64 / advertCacheCap.float64
    let ipSim = registrar.ipTree.adScore(ad)

    var w: float64 =
      discoConfig.advertExpiry * occupancy *
      (serviceSim + ipSim + discoConfig.safetyParam)

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
  finally:
    try:
      registrar.lock.release()
    except AsyncLockError as exc:
      raiseAssert exc.msg

proc updateLowerBounds*(
    registrar: Registrar,
    serviceId: ServiceId,
    ad: Advertisement,
    w: float64,
    now: uint64,
) {.async: (raises: [CancelledError]).} =
  await registrar.lock.acquire()
  try:
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
  finally:
    try:
      registrar.lock.release()
    except AsyncLockError as exc:
      raiseAssert exc.msg

proc validateRegisterMessage*(regMsg: RegisterMessage): Opt[Advertisement] =
  ## Validate a REGISTER message and decode/verify the advertisement.
  ## Returns Opt.none if the message is invalid.
  if regMsg.advertisement.len == 0:
    return Opt.none(Advertisement)

  let ad = Advertisement.decode(regMsg.advertisement).valueOr:
    error "invalid advertisement received", error
    return Opt.none(Advertisement)

  return Opt.some(ad)

proc processRetryTicket*(
    disco: ServiceDiscovery,
    regMsg: RegisterMessage,
    ad: Advertisement,
    t_wait: float64,
    now: uint64,
): float64 {.raises: [].} =
  ## Process a retry ticket if present.
  ## Returns t_wait unchanged when there is no ticket or the ticket is invalid/expired/outside window.
  ## Returns t_wait - totalWaitSoFar when the ticket is valid and the retry is within the window;
  ## a non-positive result means the peer has waited long enough and may be accepted.
  let ticketMsg = regMsg.ticket.valueOr:
    return t_wait

  if ticketMsg.advertisement != regMsg.advertisement:
    return t_wait

  let registrarPubKey = disco.switch.peerInfo.privateKey.getPublicKey().valueOr:
    error "Failed to get registrar public key", error
    return t_wait

  if not ticketMsg.verify(registrarPubKey):
    return t_wait

  if now > ticketMsg.expiresAt:
    return t_wait

  let windowStart = ticketMsg.tMod + ticketMsg.tWaitFor
  let delta = disco.discoConfig.registrationWindow.seconds.uint64
  let windowEnd = windowStart + delta

  if now >= windowStart and now <= windowEnd:
    let totalWaitSoFar = now - ticketMsg.tInit
    return t_wait - totalWaitSoFar.float64

  return t_wait

proc sendRegisterResponse*(
    conn: Connection,
    status: RegistrationStatus,
    closerPeers: seq[Peer],
    ticket: Opt[Ticket] = Opt.none(Ticket),
) {.async: (raises: [CancelledError]).} =
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

proc acceptAdvertisement*(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    ad: Advertisement,
    now: uint64,
    closerPeers: seq[Peer],
    conn: Connection,
) {.async: (raises: [CancelledError]).} =
   discard await disco.serviceRoutingTables.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConf.bucketsCount,
    Interest,
  )

  let peerKey = ad.data.peerId.toKey()
  await disco.serviceRoutingTables.insertPeer(serviceId, peerKey)

  var shouldUpdateMetrics = false

  try:
    var ads = disco.registrar.cache.getOrDefault(serviceId)

    var replaced = false
    var isDuplicate = false

    for i in 0 ..< ads.len:
      if ads[i].data.peerId == ad.data.peerId:
        if ads[i].data.seqNo == ad.data.seqNo:
          isDuplicate = true
          disco.registrar.cacheTimestamps[ads[i].toAdvertisementKey()] = now
        elif ad.data.seqNo > ads[i].data.seqNo:
          disco.registrar.ipTree.removeAd(ads[i])
          disco.registrar.cacheTimestamps.del(ads[i].toAdvertisementKey())
          ads[i] = ad
          disco.registrar.cacheTimestamps[ad.toAdvertisementKey()] = now
          disco.registrar.ipTree.insertAd(ad)
          replaced = true
          shouldUpdateMetrics = true
        else:
          isDuplicate = true
        break

    if not isDuplicate and not replaced:
      if disco.registrar.cacheTimestamps.len.uint64 >=
          disco.discoConfig.advertCacheCap.uint64:
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
          var evictAds = disco.registrar.cache.getOrDefault(evictSid)
          disco.registrar.ipTree.removeAd(evictAds[evictIdx])
          disco.registrar.cacheTimestamps.del(oldestKey)
          evictAds.delete(evictIdx)
          disco.registrar.cache[evictSid] = evictAds
          if evictSid == serviceId:
            ads = evictAds
        shouldUpdateMetrics = true

      ads.add(ad)
      disco.registrar.cacheTimestamps[ad.toAdvertisementKey()] = now
      disco.registrar.ipTree.insertAd(ad)
      shouldUpdateMetrics = true

    disco.registrar.cache[serviceId] = ads

    if shouldUpdateMetrics:
      disco.registrar.updateRegistrarMetrics()
  finally:
    try:
      disco.registrar.lock.release()
    except AsyncLockError as exc:
      raiseAssert exc.msg

  await conn.sendRegisterResponse(RegistrationStatus.Confirmed, closerPeers)

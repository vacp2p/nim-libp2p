# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, math]
import chronos, chronicles, results
import
  ../../[
    peerid, switch, multihash, cid, multicodec, multiaddress, routing_record,
    extended_peer_record,
  ]
import ../../protobuf/minprotobuf
import ../../utils/iptree
import ../../crypto/crypto
import ../kademlia
import ../kademlia/types
import ../kademlia/protobuf as kademlia_protobuf
import ./[types, routing_table_manager, service_discovery_metrics]

logScope:
  topics = "service-disco registrar"

proc updateRegistrarMetrics(registrar: Registrar) {.raises: [].} =
  cd_registrar_cache_ads.set(registrar.cacheTimestamps.len.float64)
  cd_registrar_cache_services.set(registrar.cache.len.float64)
  cd_iptree_unique_ips.set(registrar.ipTree.root.counter.float64)

proc filterIPv4(addrsInfos: seq[AddressInfo]): seq[IpAddress] {.raises: [].} =
  var ips: seq[IpAddress]
  for addrInfo in addrsInfos:
    let multiAddr = addrInfo.address
    multiAddr.getIp().withValue(ip):
      if ip.family == IpAddressFamily.IPv4:
        ips.add(ip)
  return ips

proc adScore*(ipTree: IpTree, ad: Advertisement): float64 {.raises: [].} =
  ## Return the max score for this advertisement

  var maxScore = 0.0
  for ip in ad.data.addresses.filterIPv4():
    let score = ipTree.ipScore(ip)
    if score > maxScore:
      maxScore = score

  return maxScore

proc insertAd*(ipTree: IpTree, ad: Advertisement) {.raises: [].} =
  for ip in ad.data.addresses.filterIPv4():
    ipTree.insertIp(ip)

proc removeAd*(ipTree: IpTree, ad: Advertisement) {.raises: [].} =
  for ip in ad.data.addresses.filterIPv4():
    ipTree.removeIp(ip)

proc isExpired(now, ts: Moment, expiry: Duration): bool {.inline.} =
  now - ts > expiry

proc pruneAdsForService(
    registrar: Registrar,
    serviceId: ServiceId,
    ads: var seq[Advertisement],
    now: Moment,
    advertExpiry: Duration,
    expiredCount: var int,
) =
  var i = 0
  while i < ads.len:
    let ad = ads[i]
    let key = ad.toAdvertisementKey()
    let ts = registrar.cacheTimestamps.getOrDefault(key, Moment())

    if isExpired(now, ts, advertExpiry):
      registrar.ipTree.removeAd(ad)
      registrar.cacheTimestamps.del(key)
      ads.delete(i)
      inc(expiredCount)
    else:
      inc(i)

proc pruneEmptyServices(registrar: Registrar) =
  var toRemove: seq[ServiceId] = @[]
  for sid, ads in registrar.cache:
    if ads.len == 0:
      toRemove.add(sid)

  for sid in toRemove:
    registrar.cache.del(sid)

proc pruneExpiredEntries[K](
    timestamps: var Table[K, Moment],
    bounds: var Table[K, Moment],
    now: Moment,
    expiry: Duration,
) =
  var toRemove: seq[K] = @[]

  for k, ts in timestamps:
    if isExpired(now, ts, expiry):
      toRemove.add(k)

  for k in toRemove:
    timestamps.del(k)
    bounds.del(k)

proc pruneExpiredAds*(registrar: Registrar, advertExpiry: Duration) =
  let now = Moment.now()

  var expiredCount = 0

  # Prune ads per service
  for serviceId, ads in registrar.cache.mpairs:
    registrar.pruneAdsForService(serviceId, ads, now, advertExpiry, expiredCount)

  # Remove empty services
  registrar.pruneEmptyServices()

  # Calculate metrics
  if expiredCount > 0:
    cd_registrar_ads_expired.inc(expiredCount.float64)
    registrar.updateRegistrarMetrics()

  # Expire service-level bounds
  pruneExpiredEntries(
    registrar.timestampService, registrar.boundService, now, advertExpiry
  )

  # Expire IP-level bounds
  pruneExpiredEntries(registrar.timestampIp, registrar.boundIp, now, advertExpiry)

proc waitingTime*(
    registrar: Registrar,
    discoConfig: ServiceDiscoveryConfig,
    ad: Advertisement,
    advertCacheCap: uint64,
    serviceId: ServiceId,
    now: Moment,
): Duration =
  doAssert advertCacheCap > 0, "advertCacheCap must be > 0"
  let c = registrar.cacheTimestamps.len.uint64
  let c_s = registrar.cache.getOrDefault(serviceId, @[]).len

  let occupancy =
    if c >= advertCacheCap:
      100.0
    else:
      let ratio = c.float64 / advertCacheCap.float64
      let base = max(1e-9, 1.0 - ratio)
      let exp = min(discoConfig.occupancyExp, 10.0)
      1.0 / pow(base, exp)

  let serviceSim: float64 = c_s.float64 / advertCacheCap.float64
  let ipSim = registrar.ipTree.adScore(ad)

  var w: float64 =
    discoConfig.advertExpiry.seconds.float64 * occupancy *
    (serviceSim + ipSim + discoConfig.safetyParam)

  # Bound & Quantize W
  w = max(0.0, w)
  w = min(w, float64(uint32.high))
  w = ceil(w)

  var waitDuration = chronos.seconds(w.int64)

  if serviceId in registrar.timestampService:
    let elapsedDuration =
      now - registrar.timestampService.getOrDefault(serviceId, Moment())
    let prevBoundTimestamp = registrar.boundService.getOrDefault(serviceId, Moment())
    let lowerBound = prevBoundTimestamp - elapsedDuration
    if lowerBound > now and waitDuration < lowerBound - now:
      waitDuration = lowerBound - now

  for addressInfo in ad.data.addresses:
    let ip = addressInfo.address.getIp().valueOr:
      continue

    let ipKey = $ip
    if ipKey in registrar.timestampIp:
      let elapsedDuration = now - registrar.timestampIp.getOrDefault(ipKey, Moment())
      let prevBoundTimestamp = registrar.boundIp.getOrDefault(ipKey, Moment())
      let lowerBound = prevBoundTimestamp - elapsedDuration
      if lowerBound > now and waitDuration < lowerBound - now:
        waitDuration = lowerBound - now

  return waitDuration

proc updateLowerBounds*(
    registrar: Registrar,
    serviceId: ServiceId,
    ad: Advertisement,
    waitDuration: Duration,
    now: Moment,
) =
  let prevTimestamp = registrar.timestampService.getOrDefault(serviceId, Moment())
  let prevBoundTimestamp = registrar.boundService.getOrDefault(serviceId, Moment())
  let prevWait = prevBoundTimestamp - prevTimestamp
  let elapsedDuration = now - prevTimestamp

  if waitDuration >= prevWait - elapsedDuration:
    registrar.boundService[serviceId] = now + waitDuration
    registrar.timestampService[serviceId] = now

  for addressInfo in ad.data.addresses:
    let ip = addressInfo.address.getIp().valueOr:
      continue

    let ipKey = $ip
    let prevTimestamp = registrar.timestampIp.getOrDefault(ipKey, Moment())
    let prevBoundTimestamp = registrar.boundIp.getOrDefault(ipKey, Moment())
    let prevWait = prevBoundTimestamp - prevTimestamp
    let elapsedDuration = now - prevTimestamp

    if waitDuration >= prevWait - elapsedDuration:
      registrar.boundIp[ipKey] = now + waitDuration
      registrar.timestampIp[ipKey] = now

proc validateRegisterMessage*(
    regMsg: RegisterMessage, serviceId: ServiceId
): Opt[Advertisement] =
  ## Validate a REGISTER message and decode/verify the advertisement.
  ## Returns Opt.none if the message is invalid.
  if regMsg.advertisement.len == 0:
    return Opt.none(Advertisement)

  let ad = Advertisement.decode(regMsg.advertisement).valueOr:
    error "invalid advertisement received", error
    return Opt.none(Advertisement)

  if not ad.advertisesService(serviceId):
    error "advertisement does not advertise the requested service", serviceId
    return Opt.none(Advertisement)

  return Opt.some(ad)

proc processRetryTicket*(
    disco: ServiceDiscovery,
    regMsg: RegisterMessage,
    ad: Advertisement,
    t_wait: Duration,
): Duration {.raises: [].} =
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

  let now = Moment.now()
  let windowStart = ticketMsg.tMod + ticketMsg.tWaitFor
  let windowEnd = windowStart + disco.discoConfig.registrationWindow

  if now >= windowStart and now <= windowEnd:
    let totalWaitSoFar = now - ticketMsg.tInit
    return t_wait - totalWaitSoFar

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

proc findAdIdx*(ads: seq[Advertisement], peerId: PeerId): int =
  for i in 0 ..< ads.len:
    if ads[i].data.peerId == peerId:
      return i
  -1

proc findOldestKey(disco: ServiceDiscovery): AdvertisementKey =
  var oldestKey: AdvertisementKey
  var oldestTime: Moment
  var first = true

  for k, t in disco.registrar.cacheTimestamps:
    if first or t < oldestTime:
      oldestTime = t
      oldestKey = k
      first = false

  return oldestKey

proc evictOldestAd*(
    disco: ServiceDiscovery, serviceId: ServiceId, ads: var seq[Advertisement]
) =
  let oldestKey = disco.findOldestKey()
  var emptiedSid: ServiceId
  var sidBecameEmpty = false

  block search:
    for sid, sads in disco.registrar.cache.mpairs:
      for i in 0 ..< sads.len:
        if sads[i].toAdvertisementKey() == oldestKey:
          disco.registrar.ipTree.removeAd(sads[i])
          disco.registrar.cacheTimestamps.del(oldestKey)
          sads.delete(i)

          if sid == serviceId:
            ads = sads
          elif sads.len == 0:
            emptiedSid = sid
            sidBecameEmpty = true

          break search

  if sidBecameEmpty:
    disco.registrar.cache.del(emptiedSid)

proc updateExistingAd*(
    registrar: Registrar,
    ads: var seq[Advertisement],
    idx: int,
    ad: Advertisement,
    now: Moment,
): bool =
  ## Update an advertisement that already exists in the cache for this peer.
  ## - Same seqNo: refreshes the timestamp (no structural change).
  ## - Higher seqNo: replaces the old entry in the cache and IP tree.
  ## - Lower seqNo: stale update, ignored.
  ## Returns true when the cache changed and metrics should be refreshed.
  let existing = ads[idx]
  if existing.data.seqNo == ad.data.seqNo:
    registrar.cacheTimestamps[existing.toAdvertisementKey()] = now
    return false
  elif ad.data.seqNo > existing.data.seqNo:
    registrar.ipTree.removeAd(existing)
    registrar.cacheTimestamps.del(existing.toAdvertisementKey())
    ads[idx] = ad
    registrar.cacheTimestamps[ad.toAdvertisementKey()] = now
    registrar.ipTree.insertAd(ad)
    return true
  else:
    return false

proc insertNewAd*(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    ads: var seq[Advertisement],
    ad: Advertisement,
    now: Moment,
): bool =
  ## Insert a brand-new advertisement into the cache.
  ## Evicts the globally oldest entry first if the cache is at capacity.
  ## Returns true (a new insertion always warrants a metrics update).
  if disco.registrar.cacheTimestamps.len.uint64 >= disco.discoConfig.advertCacheCap:
    evictOldestAd(disco, serviceId, ads)
  ads.add(ad)
  disco.registrar.cacheTimestamps[ad.toAdvertisementKey()] = now
  disco.registrar.ipTree.insertAd(ad)
  return true

proc acceptAdvertisement*(
    disco: ServiceDiscovery, serviceId: ServiceId, ad: Advertisement
) =
  let now = Moment.now()

  discard disco.rtManager.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Interest,
  )
  disco.rtManager.insertPeer(serviceId, ad.data.peerId.toKey())

  var ads = disco.registrar.cache.getOrDefault(serviceId)
  let idx = findAdIdx(ads, ad.data.peerId)

  let shouldUpdateMetrics =
    if idx >= 0:
      disco.registrar.updateExistingAd(ads, idx, ad, now)
    else:
      disco.insertNewAd(serviceId, ads, ad, now)

  disco.registrar.cache[serviceId] = ads

  if shouldUpdateMetrics:
    disco.registrar.updateRegistrarMetrics()

proc tInitOrDefault(ticket: Opt[Ticket], default: Moment): Moment =
  ticket.withValue(t):
    return t.tInit
  else:
    default

proc handleRegister*(
    disco: ServiceDiscovery, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let serviceId = msg.key
  let closerPeers = disco.findClosestPeers(serviceId)
  let regMsg = msg.register.valueOr:
    return

  let ad = validateRegisterMessage(regMsg, serviceId).valueOr:
    await sendRegisterResponse(
      conn, kademlia_protobuf.RegistrationStatus.Rejected, closerPeers
    )
    cd_register_requests.inc(
      labelValues = [$kademlia_protobuf.RegistrationStatus.Rejected]
    )
    return

  let now = Moment.now()
  var tWait = disco.registrar.waitingTime(
    disco.discoConfig, ad, disco.discoConfig.advertCacheCap, serviceId, now
  )
  tWait = disco.processRetryTicket(regMsg, ad, tWait)

  if tWait <= ZeroDuration:
    disco.acceptAdvertisement(serviceId, ad)
    await sendRegisterResponse(
      conn, kademlia_protobuf.RegistrationStatus.Confirmed, closerPeers
    )
    cd_register_requests.inc(
      labelValues = [$kademlia_protobuf.RegistrationStatus.Confirmed]
    )
  else:
    disco.registrar.updateLowerBounds(serviceId, ad, tWait, now)

    var ticket = Ticket(
      advertisement: regMsg.advertisement,
      tInit: regMsg.ticket.tInitOrDefault(now),
      tMod: now,
      tWaitFor: tWait,
    )
    if ticket.sign(disco.switch.peerInfo.privateKey).isErr:
      error "failed to sign ticket"
      await sendRegisterResponse(
        conn, kademlia_protobuf.RegistrationStatus.Rejected, closerPeers
      )
      cd_register_requests.inc(
        labelValues = [$kademlia_protobuf.RegistrationStatus.Rejected]
      )
      return

    await sendRegisterResponse(
      conn, kademlia_protobuf.RegistrationStatus.Wait, closerPeers, Opt.some(ticket)
    )
    cd_register_requests.inc(labelValues = [$kademlia_protobuf.RegistrationStatus.Wait])

proc handleGetAds*(
    disco: ServiceDiscovery, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  ## Handle GET_ADS request

  cd_messages_received.inc(labelValues = [$MessageType.getAds])

  let serviceId = msg.key
  let ads = disco.registrar.cache.getOrDefault(serviceId, @[])

  let cap = disco.discoConfig.fReturn

  let response = Message(
    msgType: MessageType.getAds,
    getAds: Opt.some(GetAdsMessage(advertisements: ads.encode(cap))),
    closerPeers: disco.findClosestPeers(serviceId),
  )
  let bytes = response.encode().buffer

  cd_messages_sent.inc(labelValues = [$MessageType.getAds])
  cd_message_bytes_sent.inc(bytes.len.float64, labelValues = [$MessageType.getAds])

  let writeRes = catch:
    await conn.writeLp(bytes)
  if writeRes.isErr:
    error "failed to send getAds response", err = writeRes.error.msg

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

proc hasAdReference(
    registrar: Registrar,
    key: AdvertisementKey,
    excludeSid: ServiceId = default(ServiceId),
): bool {.raises: [].} =
  ## Returns true if the ad key is still present in any service's cache list
  ## (optionally ignoring one service, e.g. the one currently being pruned).
  for sid, sads in registrar.cache:
    if sid == excludeSid:
      continue
    for a in sads:
      if a.toAdvertisementKey() == key:
        return true
  false

proc pruneAdsForService(
    registrar: Registrar,
    serviceId: ServiceId,
    ads: var seq[Advertisement],
    now: Moment,
    advertExpiry: Duration,
    expiredCount: var int,
) =
  var writeIdx = 0
  for readIdx in 0 ..< ads.len:
    let
      ad = ads[readIdx]
      key = ad.toAdvertisementKey()

    # Absent key counts as an orphan, so default to expired.
    var expired = true
    registrar.cacheTimestamps.withValue(key, ts):
      expired = isExpired(now, ts[], advertExpiry)

    if expired:
      if not hasAdReference(registrar, key, excludeSid = serviceId):
        registrar.ipTree.removeAd(ad)
        registrar.cacheTimestamps.del(key)
        inc expiredCount
    else:
      ads[writeIdx] = ad
      inc writeIdx

  ads.setLen(writeIdx)

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

  debug "pruned expired adverts", count = expiredCount

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
    (serviceSim + discoConfig.ipSimCoefficient * ipSim + discoConfig.safetyParam)

  # Bound & Quantize W
  w = max(0.0, w)
  w = min(w, float64(uint32.high))
  w = ceil(w)

  var waitDuration = w.int64.secs

  if serviceId in registrar.timestampService:
    let
      prevTimestamp = registrar.timestampService.getOrDefault(serviceId, now)
      prevBound = registrar.boundService.getOrDefault(serviceId, now)
      elapsedDuration = now - prevTimestamp
      prevWaitDuration = prevBound - prevTimestamp
    if waitDuration < prevWaitDuration - elapsedDuration:
      waitDuration = prevWaitDuration - elapsedDuration

  for addressInfo in ad.data.addresses:
    let ip = addressInfo.address.getIp().valueOr:
      continue

    let ipKey = $ip
    if ipKey in registrar.timestampIp:
      let
        prevTimestamp = registrar.timestampIp.getOrDefault(ipKey, now)
        prevBound = registrar.boundIp.getOrDefault(ipKey, now)
        elapsedDuration = now - prevTimestamp
        prevWaitDuration = prevBound - prevTimestamp
      if waitDuration < prevWaitDuration - elapsedDuration:
        waitDuration = prevWaitDuration - elapsedDuration

  return waitDuration

proc updateLowerBounds*(
    registrar: Registrar,
    serviceId: ServiceId,
    ad: Advertisement,
    waitDuration: Duration,
    now: Moment,
) =
  let prevTimestamp = registrar.timestampService.getOrDefault(serviceId, now)
  let prevBoundTimestamp = registrar.boundService.getOrDefault(serviceId, now)
  let prevWait = prevBoundTimestamp - prevTimestamp
  let elapsedDuration = now - prevTimestamp

  if waitDuration >= prevWait - elapsedDuration:
    registrar.boundService[serviceId] = now + waitDuration
    registrar.timestampService[serviceId] = now

  for addressInfo in ad.data.addresses:
    let ip = addressInfo.address.getIp().valueOr:
      continue

    let ipKey = $ip
    let prevTimestamp = registrar.timestampIp.getOrDefault(ipKey, now)
    let prevBoundTimestamp = registrar.boundIp.getOrDefault(ipKey, now)
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
    stream: Stream,
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
    await stream.writeLp(bytes)
  if writeRes.isErr:
    error "failed to send register response", err = writeRes.error.msg

proc findAdIdx*(ads: seq[Advertisement], peerId: PeerId): Opt[int] =
  for i in 0 ..< ads.len:
    if ads[i].data.peerId == peerId:
      return Opt.some(i)

  return Opt.none(int)

proc findOldestKey(disco: ServiceDiscovery): Opt[AdvertisementKey] =
  var oldestKey: AdvertisementKey
  var oldestTime = Moment.high

  for k, t in disco.registrar.cacheTimestamps:
    if t < oldestTime:
      oldestTime = t
      oldestKey = k

  if oldestTime == Moment.high:
    return Opt.none(AdvertisementKey)

  return Opt.some(oldestKey)

func findAd(registrar: Registrar, key: AdvertisementKey): Opt[Advertisement] =
  for sads in registrar.cache.values:
    for a in sads:
      if a.toAdvertisementKey() == key:
        return Opt.some(a)
  Opt.none(Advertisement)

proc removeAdFromLists(registrar: Registrar, key: AdvertisementKey): seq[ServiceId] =
  var emptiedSids: seq[ServiceId]
  for sid, sads in registrar.cache.mpairs:
    var
      writeIdx = 0
      removedHere = false
    for readIdx in 0 ..< sads.len:
      if sads[readIdx].toAdvertisementKey() == key:
        removedHere = true
      else:
        sads[writeIdx] = sads[readIdx]
        inc writeIdx
    if removedHere:
      sads.setLen(writeIdx)
      if sads.len == 0:
        emptiedSids.add(sid)
  emptiedSids

proc evictOldestAd*(
    disco: ServiceDiscovery, serviceId: ServiceId, ads: var seq[Advertisement]
) =
  let oldestKey = disco.findOldestKey().valueOr:
    return

  let oldestAd = disco.registrar.findAd(oldestKey).valueOr:
    # Stale ts entry with no list refs; just drop it
    disco.registrar.cacheTimestamps.del(oldestKey)
    return

  let emptiedSids = disco.registrar.removeAdFromLists(oldestKey)

  for sid in emptiedSids:
    disco.registrar.cache.del(sid)

  disco.registrar.ipTree.removeAd(oldestAd)
  disco.registrar.cacheTimestamps.del(oldestKey)

proc updateExistingAd*(
    registrar: Registrar,
    ads: var seq[Advertisement],
    idx: int,
    ad: Advertisement,
    now: Moment,
): bool =
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
  if disco.registrar.cacheTimestamps.len.uint64 >= disco.discoConfig.advertCacheCap:
    evictOldestAd(disco, serviceId, ads)
  ads.add(ad)
  disco.registrar.cacheTimestamps[ad.toAdvertisementKey()] = now
  disco.registrar.ipTree.insertAd(ad)
  return true

proc removeOlderAdsForPeer(
    registrar: Registrar, peerId: PeerId, newSeqNo: uint64
): bool {.raises: [].} =
  var removedAny = false
  for sid, sads in registrar.cache.mpairs:
    var i = 0
    while i < sads.len:
      let ex = sads[i]
      if ex.data.peerId == peerId and ex.data.seqNo < newSeqNo:
        let exKey = ex.toAdvertisementKey()
        sads.delete(i)
        if exKey in registrar.cacheTimestamps:
          registrar.ipTree.removeAd(ex)
          registrar.cacheTimestamps.del(exKey)
        removedAny = true
      else:
        inc(i)
  removedAny

proc upsertAdvertisementForService(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    ad: Advertisement,
    now: Moment,
    adKey: AdvertisementKey,
    peerId: PeerId,
    shouldUpdateMetrics: var bool,
) {.raises: [].} =
  var ads = disco.registrar.cache.getOrDefault(serviceId)
  let idxOpt = findAdIdx(ads, peerId)

  if idxOpt.isSome():
    let existing = ads[idxOpt.get()]
    if existing.data.seqNo == ad.data.seqNo:
      var replaced = false
      if ad.data.services.len > existing.data.services.len:
        ads[idxOpt.get()] = ad
        replaced = true
      elif ad.data.services.len == existing.data.services.len and
          ad.data.services != existing.data.services:
        ads[idxOpt.get()] = ad
        replaced = true
      if replaced:
        disco.registrar.cache[serviceId] = ads
      disco.registrar.cacheTimestamps[adKey] = now
    elif ad.data.seqNo > existing.data.seqNo:
      # Higher seqNo wins for this service.
      disco.registrar.ipTree.removeAd(existing)
      disco.registrar.cacheTimestamps.del(existing.toAdvertisementKey())
      ads[idxOpt.get()] = ad
      disco.registrar.cacheTimestamps[adKey] = now
      disco.registrar.ipTree.insertAd(ad)
      disco.registrar.cache[serviceId] = ads
      shouldUpdateMetrics = true
    else:
      # Stale (lower seqNo). Keep whatever we already have.
      disco.registrar.cache[serviceId] = ads
  else:
    if adKey in disco.registrar.cacheTimestamps:
      # This ad (by key) is already live under some other service(s).
      # Just add a reference for this service as well.
      ads.add(ad)
      disco.registrar.cache[serviceId] = ads
      disco.registrar.cacheTimestamps[adKey] = now
      shouldUpdateMetrics = true
    else:
      # Truly new advertisement globally.
      if disco.registrar.cacheTimestamps.len.uint64 >= disco.discoConfig.advertCacheCap:
        evictOldestAd(disco, serviceId, ads)
      ads.add(ad)
      disco.registrar.cacheTimestamps[adKey] = now
      disco.registrar.ipTree.insertAd(ad)
      disco.registrar.cache[serviceId] = ads
      shouldUpdateMetrics = true

proc acceptAdvertisement*(disco: ServiceDiscovery, now: Moment, ad: Advertisement) =
  let claimedServices = ad.advertisedServices()

  for sid in claimedServices:
    discard disco.rtManager.addService(
      sid, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
      Interest,
    )
    disco.rtManager.insertPeer(sid, ad.data.peerId.toKey())

  var shouldUpdateMetrics = false
  let peerId = ad.data.peerId

  if removeOlderAdsForPeer(disco.registrar, peerId, ad.data.seqNo):
    pruneEmptyServices(disco.registrar)
    shouldUpdateMetrics = true

  let adKey = ad.toAdvertisementKey()
  for sid in claimedServices:
    upsertAdvertisementForService(
      disco, sid, ad, now, adKey, peerId, shouldUpdateMetrics
    )

  if shouldUpdateMetrics:
    disco.registrar.updateRegistrarMetrics()

proc tInitOrDefault(ticket: Opt[Ticket], default: Moment): Moment =
  ticket.withValue(t):
    return t.tInit
  else:
    default

proc getCloserPeers(
    disco: ServiceDiscovery, serviceId: ServiceId, count: int
): seq[Peer] =
  let table = disco.rtManager.getTable(serviceId).get(disco.rtable)

  let keys = table.randomPeersClosestFirst(
    disco.rng, count, maxPerBucket = disco.discoConfig.kRegister
  )

  return disco.switch.toPeers(keys)

proc registration*(disco: ServiceDiscovery, peerId: PeerId, inMsg: Message): Message =
  let serviceId = inMsg.key

  # Add peer to both tables
  discard disco.rtable.insert(peerId)
  disco.rtManager.insertPeer(serviceId, peerId.toKey())

  let closerPeers = disco.getCloserPeers(serviceId, disco.discoConfig.fReturn)

  var msg = Message(
    msgType: MessageType.register,
    register: Opt.some(
      RegisterMessage(
        advertisement: @[],
        status: Opt.some(kademlia_protobuf.RegistrationStatus.Rejected),
        ticket: Opt.none(Ticket),
      )
    ),
    closerPeers: closerPeers,
  )

  let regMsg = inMsg.register.valueOr:
    error "no register message"

    cd_register_requests.inc(
      labelValues = [$kademlia_protobuf.RegistrationStatus.Rejected]
    )

    return msg

  let ad = validateRegisterMessage(regMsg, serviceId).valueOr:
    error "invalid register message"

    cd_register_requests.inc(
      labelValues = [$kademlia_protobuf.RegistrationStatus.Rejected]
    )

    return msg

  let now = Moment.now()
  var tWait = disco.registrar.waitingTime(
    disco.discoConfig, ad, disco.discoConfig.advertCacheCap, serviceId, now
  )
  tWait = disco.processRetryTicket(regMsg, ad, tWait)

  if tWait <= ZeroDuration:
    disco.acceptAdvertisement(now, ad)

    msg.register.get().status.get() = kademlia_protobuf.RegistrationStatus.Confirmed

    cd_register_requests.inc(
      labelValues = [$kademlia_protobuf.RegistrationStatus.Confirmed]
    )

    return msg

  disco.registrar.updateLowerBounds(serviceId, ad, tWait, now)

  var ticket = Ticket(
    advertisement: regMsg.advertisement,
    tInit: regMsg.ticket.tInitOrDefault(now),
    tMod: now,
    tWaitFor: tWait,
  )

  if ticket.sign(disco.switch.peerInfo.privateKey).isErr:
    error "failed to sign ticket"

    cd_register_requests.inc(
      labelValues = [$kademlia_protobuf.RegistrationStatus.Rejected]
    )

    return msg

  msg.register.get().status.get() = kademlia_protobuf.RegistrationStatus.Wait
  msg.register.get().ticket = Opt.some(ticket)

  cd_register_requests.inc(labelValues = [$kademlia_protobuf.RegistrationStatus.Wait])

  return msg

proc getAdvertisements*(
    disco: ServiceDiscovery, peerId: PeerId, msg: Message
): Message =
  let serviceId = msg.key

  # Add peer to both tables
  discard disco.rtable.insert(peerId)
  disco.rtManager.insertPeer(serviceId, peerId.toKey())

  let ads = disco.registrar.cache.getOrDefault(serviceId, @[])

  let cap = disco.discoConfig.fReturn

  let closerPeers = disco.getCloserPeers(serviceId, cap)

  let response = Message(
    msgType: MessageType.getAds,
    getAds: Opt.some(GetAdsMessage(advertisements: ads.encode(cap))),
    closerPeers: closerPeers,
  )

  return response

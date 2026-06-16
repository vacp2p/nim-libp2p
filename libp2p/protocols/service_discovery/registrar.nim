# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, math]
import chronos, chronicles, results
import
  ../../[
    peerid, switch, multihash, cid, multicodec, multiaddress, routing_record,
    extended_peer_record,
  ]
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

proc isExpired(now, ts: Moment, expiry: Duration): bool =
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
    registrar.cacheTimestamps.withValue(key, ts):
      if isExpired(now, ts[], advertExpiry):
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
  w = round(w)

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

proc isValidAdvertisement*(
    regMsg: RegisterMessage, serviceId: ServiceId
): Result[Advertisement, string] =
  let advertisment = regMsg.advertisement.valueOr:
    return err("advertisement not set")

  if advertisment.len > MaxXPRSize:
    return err("oversized")

  let ad = Advertisement.decode(advertisment).valueOr:
    return err("cannot decode: " & $error)

  for svc in ad.data.services:
    if not svc.isValid():
      return err("oversized service data")

  if not ad.advertisesService(serviceId):
    return err("message & advertisement service mismatch")

  return ok(ad)

proc updateWaitAfterRetry*(
    disco: ServiceDiscovery, ticketOpt: Opt[Ticket], now: Moment, wait: var Duration
) =
  ticketOpt.withValue(ticket):
    let totalWaitSoFar = now - ticket.tInit.get()
    wait -= totalWaitSoFar

proc isValidTicket(
    disco: ServiceDiscovery, regMsg: RegisterMessage, now: Moment
): Result[Opt[Ticket], string] {.raises: [].} =
  let ticket = regMsg.ticket.valueOr:
    return ok(Opt.none(Ticket))

  if ticket.advertisement.get(@[]) != regMsg.advertisement.get(@[]):
    return err("message & ticket advertisement mismatch")

  let registrarPubKey = disco.switch.peerInfo.privateKey.getPublicKey().valueOr:
    return err("failed to get registrar public key")

  if not ticket.verify(registrarPubKey):
    return err("ticket fails verification")

  let
    windowStart = ticket.tMod.get() + ticket.tWaitFor.get()
    windowEnd = windowStart + disco.discoConfig.registrationWindow

  if now notin windowStart .. windowEnd:
    return err("ticket outside valid time window")

  return ok(Opt.some(ticket))

proc sendRegisterResponse*(
    stream: Stream,
    status: RegistrationStatus,
    closerPeers: seq[Peer],
    ticket: Opt[Ticket] = Opt.none(Ticket),
) {.async: (raises: [CancelledError]).} =
  let msg = Message(
    msgType: Opt.some(MessageType.register),
    register: Opt.some(
      RegisterMessage(
        advertisement: Opt.none(seq[byte]), status: Opt.some(status), ticket: ticket
      )
    ),
    closerPeers: closerPeers,
  )
  let bytes = msg.encode()
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

proc evictOldestAd*(
    disco: ServiceDiscovery, serviceId: ServiceId, ads: var seq[Advertisement]
) =
  let oldestKey = disco.findOldestKey().valueOr:
    return

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
    disco: ServiceDiscovery, now: Moment, serviceId: ServiceId, ad: Advertisement
) =
  discard disco.rtManager.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Interest,
  )
  disco.rtManager.insertPeer(serviceId, ad.data.peerId.toKey())

  var ads = disco.registrar.cache.getOrDefault(serviceId)

  var shouldUpdateMetrics: bool
  let idxOpt = findAdIdx(ads, ad.data.peerId)
  shouldUpdateMetrics =
    if idxOpt.isSome():
      disco.registrar.updateExistingAd(ads, idxOpt.get(), ad, now)
    else:
      disco.insertNewAd(serviceId, ads, ad, now)

  disco.registrar.cache[serviceId] = ads

  if shouldUpdateMetrics:
    disco.registrar.updateRegistrarMetrics()

proc getCloserPeers(
    disco: ServiceDiscovery, serviceId: ServiceId, count: int
): seq[Peer] =
  let table = disco.rtManager.getTable(serviceId).get(disco.rtable)

  let keys = table.randomPeersClosestFirst(
    disco.rng, count, maxPerBucket = disco.discoConfig.kRegister
  )

  return disco.switch.toPeers(keys)

proc registration*(disco: ServiceDiscovery, peerId: PeerId, inMsg: Message): Message =
  let serviceId = inMsg.key.valueOr:
    error "Key not set: registration", msg = inMsg
    return

  # Add peer to both tables
  discard disco.rtable.insert(peerId)
  disco.rtManager.insertPeer(serviceId, peerId.toKey())

  let closerPeers = disco.getCloserPeers(serviceId, disco.discoConfig.fReturn)

  var msg = Message(
    msgType: Opt.some(MessageType.register),
    register: Opt.some(
      RegisterMessage(
        advertisement: Opt.none(seq[byte]),
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

  let ad = isValidAdvertisement(regMsg, serviceId).valueOr:
    error "invalid advertisement", error

    cd_register_requests.inc(
      labelValues = [$kademlia_protobuf.RegistrationStatus.Rejected]
    )

    return msg

  let now = Moment.now()

  let ticketOpt = disco.isValidTicket(regMsg, now).valueOr:
    error "invalid ticket", error

    cd_register_requests.inc(
      labelValues = [$kademlia_protobuf.RegistrationStatus.Rejected]
    )

    return msg

  var tWait = disco.registrar.waitingTime(
    disco.discoConfig, ad, disco.discoConfig.advertCacheCap, serviceId, now
  )

  disco.updateWaitAfterRetry(ticketOpt, now, tWait)

  if tWait <= ZeroDuration:
    disco.acceptAdvertisement(now, serviceId, ad)

    msg.register.get().status.get() = kademlia_protobuf.RegistrationStatus.Confirmed

    cd_register_requests.inc(
      labelValues = [$kademlia_protobuf.RegistrationStatus.Confirmed]
    )

    return msg

  disco.registrar.updateLowerBounds(serviceId, ad, tWait, now)

  var ticket = Ticket(
    advertisement: regMsg.advertisement,
    tInit: Opt.some(now),
    tMod: Opt.some(now),
    tWaitFor: Opt.some(tWait),
  )

  regMsg.ticket.withValue(t):
    let
      windowStart = t.tMod.get() + t.tWaitFor.get()
      windowEnd = windowStart + disco.discoConfig.registrationWindow
    if now in windowStart .. windowEnd:
      ticket.tInit = t.tInit

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
  let serviceId = msg.key.valueOr:
    error "Key not set: getAdvertisements", msg = msg
    return

  # Add peer to both tables
  discard disco.rtable.insert(peerId)
  disco.rtManager.insertPeer(serviceId, peerId.toKey())

  let ads = disco.registrar.cache.getOrDefault(serviceId, @[])

  let cap = disco.discoConfig.fReturn

  let closerPeers = disco.getCloserPeers(serviceId, cap)

  let response = Message(
    msgType: Opt.some(MessageType.getAds),
    getAds: Opt.some(GetAdsMessage(advertisements: ads.encode(cap))),
    closerPeers: closerPeers,
  )

  return response

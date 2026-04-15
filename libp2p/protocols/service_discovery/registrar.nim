# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, math, times]
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
  ## Return the max score for this advertisment

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

proc pruneExpiredAds*(registrar: Registrar, advertExpiry: uint64) =
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

proc waitingTime*(
    registrar: Registrar,
    discoConfig: ServiceDiscoveryConfig,
    ad: Advertisement,
    advertCacheCap: uint64,
    serviceId: ServiceId,
    now: uint64,
): float64 =
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
    discoConfig.advertExpiry.seconds.float64 * occupancy *
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

proc updateLowerBounds*(
    registrar: Registrar,
    serviceId: ServiceId,
    ad: Advertisement,
    w: float64,
    now: uint64,
) =
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

proc findAdIdx*(ads: seq[Advertisement], peerId: PeerId): int =
  for i in 0 ..< ads.len:
    if ads[i].data.peerId == peerId:
      return i
  -1

proc findOldestKey(disco: ServiceDiscovery): AdvertisementKey =
  var oldestKey: AdvertisementKey
  var oldestTime = high(uint64)

  for k, t in disco.registrar.cacheTimestamps:
    if t < oldestTime:
      oldestTime = t
      oldestKey = k

  return oldestKey

proc evictOldestAd*(
    disco: ServiceDiscovery, serviceId: ServiceId, ads: var seq[Advertisement]
) =
  let oldestKey = disco.findOldestKey()

  for sid, sads in disco.registrar.cache.mpairs:
    for i in 0 ..< sads.len:
      if sads[i].toAdvertisementKey() == oldestKey:
        disco.registrar.ipTree.removeAd(sads[i])
        disco.registrar.cacheTimestamps.del(oldestKey)
        sads.delete(i)

        if sid == serviceId:
          ads = sads

        return

proc updateExistingAd*(
    registrar: Registrar,
    ads: var seq[Advertisement],
    idx: int,
    ad: Advertisement,
    now: uint64,
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
    now: uint64,
): bool =
  ## Insert a brand-new advertisement into the cache.
  ## Evicts the globally oldest entry first if the cache is at capacity.
  ## Returns true (a new insertion always warrants a metrics update).
  if disco.registrar.cacheTimestamps.len.uint64 >=
      disco.discoConfig.advertCacheCap.uint64:
    evictOldestAd(disco, serviceId, ads)
  ads.add(ad)
  disco.registrar.cacheTimestamps[ad.toAdvertisementKey()] = now
  disco.registrar.ipTree.insertAd(ad)
  return true

proc acceptAdvertisement*(
    disco: ServiceDiscovery, serviceId: ServiceId, ad: Advertisement
) =
  let now = getTime().toUnix().uint64

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

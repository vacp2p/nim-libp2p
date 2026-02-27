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
import ./[types, iptree, serviceroutingtables, capability_discovery_metrics]

logScope:
  topics = "cap-disco registrar"

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

proc pruneExpiredAds*(registrar: Registrar, advertExpiry: uint64) {.raises: [].} =
  ## Remove expired advertisements from cache

  let now = getTime().toUnix().uint64
  var toDelete: seq[tuple[serviceId: ServiceId, ad: Advertisement]] = @[]

  for serviceId, ads in registrar.cache.mpairs:
    var i = 0
    while i < ads.len:
      let ad = ads[i]
      let adKey = ad.toAdvertisementKey()
      let adTime = registrar.cacheTimestamps.getOrDefault(adKey, 0)
      if now - adTime > advertExpiry:
        # Expired - remove from IP tree
        registrar.ipTree.removeAd(ad)
        toDelete.add((serviceId, ad))
        ads.delete(i)
      else:
        inc(i)

  for (serviceId, ad) in toDelete:
    let adKey = ad.toAdvertisementKey()
    registrar.cacheTimestamps.del(adKey)

  if toDelete.len > 0:
    cd_registrar_ads_expired.inc(toDelete.len.float64)
    registrar.updateRegistrarMetrics()

proc waitingTime*(
    registrar: Registrar,
    discoConf: KademliaDiscoveryConfig,
    ad: Advertisement,
    advertCacheCap: uint64,
    serviceId: ServiceId,
    now: uint64,
): float64 {.raises: [].} =
  ## Calculate waiting time for advertisement registration with lower bound enforcement

  let c = registrar.cacheTimestamps.len.uint64
  let c_s = registrar.cache.getOrDefault(serviceId, @[]).len

  let occupancy: float64 =
    if c >= advertCacheCap:
      100.0 # Cap at high value when full
    else:
      1.0 / pow(1.0 - c.float64 / advertCacheCap.float64, discoConf.occupancyExp)

  let serviceSim: float64 = c_s.float64 / advertCacheCap.float64

  var ipKeys: seq[string] = @[]
  for addressInfo in ad.data.addresses:
    let multiaddr = addressInfo.address
    let ip = multiaddr.getIp().valueOr:
      continue
    ipKeys.add($ip)

  let ipSim = registrar.ipTree.adScore(ad)

  # Calculate initial waiting time
  var w: float64 =
    discoConf.advertExpiry * occupancy * (serviceSim + ipSim + discoConf.safetyParam)

  # Enforce service ID lower bound (RFC section: Lower Bound Enforcement)
  # w_s = max(w_s, bound(service_id_hash) - (now - timestamp(service_id_hash)))
  if serviceId in registrar.timestampService:
    let elapsedService = now - registrar.timestampService.getOrDefault(serviceId, 0)
    let boundServiceVal = registrar.boundService.getOrDefault(serviceId, 0.0)
    let serviceLowerBound = boundServiceVal - elapsedService.float64
    if serviceLowerBound > w:
      w = serviceLowerBound

  # Enforce IP lower bound for all IPs
  # w_ip = max(w_s, bound(IP) - (now - timestamp(IP)))
  # Check all IPs and use the most restrictive bound
  for ipKey in ipKeys:
    if ipKey in registrar.timestampIp:
      let elapsedIp = now - registrar.timestampIp.getOrDefault(ipKey, 0)
      let boundIpVal = registrar.boundIp.getOrDefault(ipKey, 0.0)
      let ipLowerBound = boundIpVal - elapsedIp.float64
      if ipLowerBound > w:
        w = ipLowerBound

  return w

proc updateLowerBounds*(
    registrar: Registrar,
    serviceId: ServiceId,
    ad: Advertisement,
    w: float64,
    now: uint64,
) {.raises: [].} =
  ## Update lower bound state for service and IP (RFC section: Lower Bound Enforcement)
  # Update service lower bound if w exceeds current lower bound
  let elapsedService = now - registrar.timestampService.getOrDefault(serviceId, 0)

  let boundServiceVal = registrar.boundService.getOrDefault(serviceId, 0.0)
  if w > boundServiceVal - elapsedService.float64:
    registrar.boundService[serviceId] = w + now.float64
    registrar.timestampService[serviceId] = now

  # Update IP lower bound for all IPs if w exceeds current lower bound
  for addressInfo in ad.data.addresses:
    let multiaddr = addressInfo.address
    let ip = multiaddr.getIp().valueOr:
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
  let delta = disco.discoConf.registerationWindow.seconds.uint64
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
  ## Accept and store advertisement, send Confirmed response

  disco.serviceRoutingTables.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConf.bucketsCount,
    Interest,
  )

  let peerKey = ad.data.peerId.toKey()
  disco.serviceRoutingTables.insertPeer(serviceId, peerKey)

  var ads = disco.registrar.cache.getOrDefault(serviceId)

  # Check for duplicate - verify both serviceId and peerId match
  # This prevents overwriting ads from different peers with same peerId
  var isDuplicate = false
  for existingAd in ads:
    if existingAd.data.peerId == ad.data.peerId:
      isDuplicate = true
      # Update timestamp for the existing ad
      let existingKey = existingAd.toAdvertisementKey()
      disco.registrar.cacheTimestamps[existingKey] = now
      break

  if not isDuplicate:
    ads.add(ad)
    let adKey = ad.toAdvertisementKey()
    disco.registrar.cacheTimestamps[adKey] = now
    disco.registrar.ipTree.insertAd(ad)
    disco.registrar.updateRegistrarMetrics()

  disco.registrar.cache[serviceId] = ads

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
  ## Handle REGISTER request

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

  disco.registrar.pruneExpiredAds(disco.discoConf.advertExpiry.uint64)

  let t_wait = disco.registrar.waitingTime(
    disco.discoConf, ad, disco.discoConf.advertCacheCap.uint64, serviceId, now
  )

  disco.registrar.updateLowerBounds(serviceId, ad, t_wait, now)

  let t_remaining = disco.processRetryTicket(regMsg, ad, t_wait, now)

  if t_remaining <= 0:
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

  return

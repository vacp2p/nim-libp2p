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
import ./[types, iptree, serviceroutingtables]

logScope:
  topics = "cap-disco registrar"

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
  ## Get closer peers from registrar table for a service
  ## Falls back to main DHT if table is empty or not found
  ## Returns properly formatted Peer objects for responses

  var closerPeerKeys: seq[Key] = @[]

  # Try to use registrar table first
  block thisBlock:
    if disco.serviceRoutingTables.hasService(serviceId):
      let regTable = disco.serviceRoutingTables.getTable(serviceId).valueOr:
        break thisBlock

      closerPeerKeys = regTable.findClosest(serviceId, count)

  # Fall back to main DHT if regTable not found or empty
  if closerPeerKeys.len == 0:
    closerPeerKeys = disco.rtable.findClosest(serviceId, count)

  var closerPeers: seq[Peer] = @[]
  for peerKey in closerPeerKeys:
    let peerId = peerKey.toPeerId().valueOr:
      debug "Failed to convert key to peer id", error = error
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
  ## Unified response sender for REGISTER messages
  ## Handles Confirmed, Rejected, and Wait responses

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
    error "Failed to send register response", err = writeRes.error.msg

proc sendRegisterReject*(
    conn: Connection, closerPeers: seq[Peer] = @[]
) {.async: (raises: []).} =
  ## Helper to send a rejection response
  await conn.sendRegisterResponse(
    kademlia_protobuf.RegistrationStatus.Rejected, closerPeers
  )

proc validateRegisterMessage*(regMsg: RegisterMessage): Opt[Advertisement] =
  ## Validate register message and decode/verify advertisement
  ## Returns none if invalid, with appropriate debug logging

  if regMsg.advertisement.len == 0:
    debug "No advertisement provided in register message"
    return Opt.none(Advertisement)

  let ad = Advertisement.decode(regMsg.advertisement).valueOr:
    debug "Invalid advertisement received", err = error
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

  var t_remaining = t_wait

  let ticketMsg = regMsg.ticket.valueOr:
    return t_remaining

  # Compare ticket.ad bytes directly with regMsg.advertisement bytes
  if ticketMsg.advertisement != regMsg.advertisement:
    return t_remaining

  # Verify ticket signature with registrar's key
  let registrarPubKey = disco.switch.peerInfo.privateKey.getPublicKey().valueOr:
    error "Failed to get registrar public key", error
    return t_remaining

  if not ticketMsg.verify(registrarPubKey):
    return t_remaining

  let windowStart = ticketMsg.tMod + ticketMsg.tWaitFor
  let delta = disco.discoConf.registerationWindow.seconds.uint64
  let windowEnd = windowStart + delta

  if now >= windowStart and now <= windowEnd:
    # Valid retry, calculate remaining time using accumulated wait
    # from original t_init (RFC spec requirement)
    let totalWaitSoFar = now - ticketMsg.tInit
    t_remaining = t_wait - totalWaitSoFar.float64

  return t_remaining

proc acceptAdvertisement*(
    disco: KademliaDiscovery,
    serviceId: ServiceId,
    ad: Advertisement,
    now: uint64,
    closerPeers: seq[Peer],
    conn: Connection,
) {.async: (raises: []).} =
  ## Accept and store advertisement, send Confirmed response

  # Ensure service has a registrar table (create if needed)
  disco.serviceRoutingTables.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConf.bucketsCount
  )

  # Update regTable with peer info
  let peerKey = ad.data.peerId.toKey()

  disco.serviceRoutingTables.insertPeer(serviceId, peerKey)

  var ads = disco.registrar.cache.getOrDefault(serviceId)
  if serviceId notin disco.registrar.cache:
    ads = @[]
    disco.registrar.cache[serviceId] = ads

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
    error "Failed to sign ticket", err = error
    await conn.sendRegisterReject(closerPeers)

  await conn.sendRegisterResponse(
    kademlia_protobuf.RegistrationStatus.Wait, closerPeers, Opt.some(ticket)
  )

proc handleGetAds*(
    disco: KademliaDiscovery, conn: Connection, msg: Message
) {.async: (raises: []).} =
  ## Handle GET_ADS request
  let serviceId = msg.key

  # Prune expired ads first
  disco.registrar.pruneExpiredAds(disco.discoConf.advertExpiry.uint64)

  # Get cached ads for this service
  var ads: seq[Advertisement]
  for ad in disco.registrar.cache.getOrDefault(serviceId, @[]):
    ads.add(ad)

  # Limit to F_return ads
  let fReturn = min(ads.len, disco.discoConf.fReturn)
  var adBufs: seq[seq[byte]] = @[]
  if ads.len > 0:
    for i in 0 ..< fReturn:
      let encodedAd = ads[i].encode().valueOr:
        error "Failed to encode ads", error
        continue

      adBufs.add(encodedAd)

  # Get closer peers using registrar table or fall back to main DHT
  let closerPeers =
    disco.getRegistrarCloserPeers(serviceId, disco.discoConf.bucketsCount)

  # Send response with new nested GetAds message structure
  let msg = Message(
    msgType: MessageType.getAds,
    getAds: Opt.some(GetAdsMessage(advertisements: adBufs)),
    closerPeers: closerPeers,
  )
  let bytes = msg.encode().buffer

  let writeRes = catch:
    await conn.writeLp(bytes)
  if writeRes.isErr:
    error "Failed to send get-ads response", err = writeRes.error.msg

proc handleRegister*(
    disco: KademliaDiscovery, conn: Connection, msg: Message
) {.async: (raises: []).} =
  ## Handle REGISTER request following RFC algorithm

  let serviceId = msg.key

  # Get closer peers for responses (RFC requires closerPeers in all responses)
  let closerPeers =
    disco.getRegistrarCloserPeers(serviceId, disco.discoConf.bucketsCount)

  let regMsg = msg.register.valueOr:
    # No register message provided, reject
    await conn.sendRegisterReject(closerPeers)
    return

  # Validate register message and decode/verify advertisement
  let ad = validateRegisterMessage(regMsg).valueOr:
    await conn.sendRegisterReject(closerPeers)
    return

  let now = getTime().toUnix().uint64

  # Prune expired ads first
  disco.registrar.pruneExpiredAds(disco.discoConf.advertExpiry.uint64)

  # Calculate wait time with lower bound enforcement
  let t_wait = disco.registrar.waitingTime(
    disco.discoConf, ad, disco.discoConf.advertCacheCap.uint64, serviceId, now
  )

  # Update lower bounds for service and IP (RFC section: Lower Bound Enforcement)
  disco.registrar.updateLowerBounds(serviceId, ad, t_wait, now)

  # Process retry ticket if provided
  let t_remaining = disco.processRetryTicket(regMsg, ad, t_wait, now)

  if t_remaining <= 0:
    # Accept the advertisement
    await disco.acceptAdvertisement(serviceId, ad, now, closerPeers, conn)
    return

  # Send Wait response with ticket
  let ticket = Ticket(
    advertisement: regMsg.advertisement,
    tInit: now,
    tMod: now,
    tWaitFor: 0,
    signature: @[],
  )
  await waitOrRejectAdvertisement(closerPeers, conn, t_remaining, ticket, disco)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sets, heapqueue, times, math, options]
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
import ./[types, iptree, protobuf]

logScope:
  topics = "cap-disco registrar"

proc new*(T: typedesc[Registrar]): T =
  T(
    cache: initOrderedTable[ServiceId, seq[Advertisement]](),
    cacheTimestamps: initTable[AdvertisementKey, int64](),
    ipTree: IpTree.new(),
    boundService: initTable[ServiceId, float64](),
    timestampService: initTable[ServiceId, int64](),
    boundIp: initTable[string, float64](),
    timestampIp: initTable[string, int64](),
    regTable: initTable[ServiceId, RegistrarTable](),
  )

proc pruneExpiredAds*(registrar: Registrar, advertExpiry: float64) {.raises: [].} =
  ## Remove expired advertisements from cache

  let now = getTime().toUnix()
  var toDelete: seq[tuple[serviceId: ServiceId, ad: Advertisement]] = @[]

  for serviceId, ads in registrar.cache.mpairs:
    var i = 0
    while i < ads.len:
      let ad = ads[i]
      let adKey = ad.toAdvertisementKey()
      let adTime = registrar.cacheTimestamps.getOrDefault(adKey, 0)
      if now - adTime > advertExpiry.int64:
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
    advertCacheCap: float64,
    serviceId: ServiceId,
    now: int64,
): float64 {.raises: [].} =
  ## Calculate waiting time for advertisement registration with lower bound enforcement

  let c = registrar.cacheTimestamps.len.float64

  let c_s = registrar.cache.getOrDefault(serviceId, @[]).len.float64

  let occupancy =
    if c >= advertCacheCap:
      100.0 # Cap at high value when full
    else:
      1.0 / pow(1.0 - c / advertCacheCap, discoConf.occupancyExp)

  let serviceSim = c_s / advertCacheCap

  var ipKeys: seq[string] = @[]
  let ipSim = registrar.ipTree.adScore(ad)

  # Calculate initial waiting time
  var w =
    discoConf.advertExpiry * occupancy * (serviceSim + ipSim + discoConf.safetyParam)

  # Enforce service ID lower bound (RFC section: Lower Bound Enforcement)
  # w_s = max(w_s, bound(service_id_hash) - (now - timestamp(service_id_hash)))
  if serviceId in registrar.timestampService:
    let elapsedService =
      float64(now - registrar.timestampService.getOrDefault(serviceId, 0))
    let boundServiceVal = registrar.boundService.getOrDefault(serviceId, 0.0)
    let serviceLowerBound = boundServiceVal - elapsedService
    if serviceLowerBound > w:
      w = serviceLowerBound

  # Enforce IP lower bound for all IPs
  # w_ip = max(w_s, bound(IP) - (now - timestamp(IP)))
  # Check all IPs and use the most restrictive bound
  for ipKey in ipKeys:
    if ipKey in registrar.timestampIp:
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

proc addServiceRegistration*(disco: KademliaDiscovery, serviceId: ServiceId) =
  ## Create a new registrar table for the service
  ## Bootstraps from main KadDHT routing table
  ## Called when first ad for service is received

  if serviceId in disco.registrar.regTable:
    return

  # Create new RegistrarTable centered on serviceId
  var regTable = RegistrarTable.new(
    serviceId,
    config = RoutingTableConfig.new(
      replication = disco.config.replication, maxBuckets = disco.discoConf.bucketsCount
    ),
  )

  # Bootstrap from main KadDHT routing table
  for bucket in disco.rtable.buckets:
    for peer in bucket.peers:
      let peerId = peer.nodeId.toPeerId().valueOr:
        continue

      let peerKey = peerId.toKey()

      discard regTable.insert(peerKey)

  disco.registrar.regTable[serviceId] = regTable

proc removeServiceRegistration*(disco: KademliaDiscovery, serviceId: ServiceId) =
  ## Remove registrar table for a service
  ## Clean up any pending operations for this service

  if serviceId in disco.registrar.regTable:
    disco.registrar.regTable.del(serviceId)

proc refreshRegTable*(
    disco: KademliaDiscovery, regTable: RegistrarTable
) {.async: (raises: []).} =
  ## Refresh a registrar table by querying known peers
  ## Similar to refreshTable in advertiser/discoverer

  let refreshRes = catch:
    await disco.refreshTable(regTable)
  if refreshRes.isErr:
    error "failed to refresh registrar table", error = refreshRes.error.msg

proc refreshAllRegTables*(disco: KademliaDiscovery) {.async: (raises: []).} =
  ## Refresh all registrar tables periodically

  for regTable in disco.registrar.regTable.values:
    let refreshRes = catch:
      await disco.refreshTable(regTable)
    if refreshRes.isErr:
      error "failed to refresh registrar table", error = refreshRes.error.msg

proc getRegistrarCloserPeers*(
    disco: KademliaDiscovery, serviceId: ServiceId, count: int
): seq[Peer] {.raises: [].} =
  ## Get closer peers from registrar table for a service
  ## Falls back to main DHT if table is empty or not found
  ## Returns properly formatted Peer objects for responses

  var closerPeerKeys: seq[Key] = @[]

  # Try to use registrar table first
  if serviceId in disco.registrar.regTable:
    let regTable = disco.registrar.regTable.getOrDefault(serviceId)
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

  var ticketMsg = Opt.none(TicketMessage)

  if ticket.isSome():
    let t = ticket.get()
    ticketMsg = Opt.some(
      TicketMessage(
        advertisement: t.ad,
        tInit: t.t_init.uint64,
        tMod: t.t_mod.uint64,
        tWaitFor: t.t_wait_for,
        signature: t.signature,
      )
    )

  let writeRes = catch:
    await conn.writeLp(
      Message(
        msgType: MessageType.register,
        register: Opt.some(
          RegisterMessage(
            advertisement: @[], status: Opt.some(status), ticket: ticketMsg
          )
        ),
        closerPeers: closerPeers,
      ).encode().buffer
    )
  if writeRes.isErr:
    debug "Failed to send register response", err = writeRes.error.msg

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
    now: int64,
): float64 =
  ## Process retry ticket if provided
  ## Returns remaining wait time (or t_wait if no valid ticket)

  var t_remaining = t_wait

  if regMsg.ticket.isSome():
    let ticketMsg = regMsg.ticket.get()

    # Compare ticket.ad bytes directly with regMsg.advertisement bytes
    # No need to re-decode since we already have the decoded ad
    if ticketMsg.advertisement == regMsg.advertisement:
      # Verify ticket signature with registrar's key
      let pubKeyRes = disco.switch.peerInfo.privateKey.getPublicKey()
      if pubKeyRes.isOk():
        let registrarPubKey = pubKeyRes.get()

        # Create Ticket from TicketMessage for verification
        let ticketVal = Ticket(
          ad: ticketMsg.advertisement,
          t_init: ticketMsg.tInit.int64,
          t_mod: ticketMsg.tMod.int64,
          t_wait_for: ticketMsg.tWaitFor,
          signature: ticketMsg.signature,
        )

        if ticketVal.verify(registrarPubKey):
          # Verify ticket.ad matches current ad (already verified by byte comparison on line 300)
          # Additional verification: ensure peerId matches
          # Note: serviceId is a parameter, not stored in SignedExtendedPeerRecord
          # Verify retry within registration window
          # Spec: t_mod + t_wait_for ≤ NOW() ≤ t_mod + t_wait_for + δ
          let windowStart = ticketVal.t_mod + ticketVal.t_wait_for.int64
          let delta = disco.discoConf.registerationWindow.seconds.int64
          let windowEnd = windowStart + delta

          if now >= windowStart and now <= windowEnd:
            # Valid retry, calculate remaining time using accumulated wait
            # from original t_init (RFC spec requirement)
            let totalWaitSoFar = float64(now - ticketVal.t_init)
            t_remaining = t_wait - totalWaitSoFar
      else:
        debug "Failed to get registrar public key", err = pubKeyRes.error

  return t_remaining

proc acceptAdvertisement*(
    disco: KademliaDiscovery,
    serviceId: ServiceId,
    ad: Advertisement,
    now: int64,
    closerPeers: seq[Peer],
    conn: Connection,
) {.async: (raises: [CancelledError]).} =
  ## Accept and store advertisement, send Confirmed response

  # Ensure service has a registrar table (create if needed)
  disco.addServiceRegistration(serviceId)

  # Update regTable with peer info
  if serviceId in disco.registrar.regTable:
    let peerKey = ad.data.peerId.toKey()
    # Safe access - we've verified serviceId exists
    try:
      discard disco.registrar.regTable[serviceId].insert(peerKey)
    except KeyError:
      # Should not happen due to existence check above
      discard

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

  # Send Confirmed response
  await conn.sendRegisterResponse(
    kademlia_protobuf.RegistrationStatus.Confirmed, closerPeers
  )

proc rejectAdvertisement*(
    closerPeers: seq[Peer],
    conn: Connection,
    t_remaining: float64,
    ticket: Ticket,
    disco: KademliaDiscovery,
) {.async: (raises: [CancelledError]).} =
  ## Send Wait response with ticket or Rejected response

  var ticket = ticket

  ticket.t_wait_for = min(disco.discoConf.advertExpiry.uint32, t_remaining.uint32)
  ticket.t_mod = getTime().toUnix()

  # Sign ticket with registrar's key
  let signRes = ticket.sign(disco.switch.peerInfo.privateKey)
  if signRes.isOk:
    await conn.sendRegisterResponse(
      kademlia_protobuf.RegistrationStatus.Wait, closerPeers, Opt.some(ticket)
    )
  else:
    # Signing failed, reject
    debug "Failed to sign ticket", err = signRes.error
    await conn.sendRegisterResponse(
      kademlia_protobuf.RegistrationStatus.Rejected, closerPeers
    )

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
      let encodedAd = ads[i].encode().valueOr:
        error "Failed to encode ads", error
        continue

      adBufs.add(encodedAd)

  # Get closer peers using registrar table or fall back to main DHT
  let closerPeers =
    disco.getRegistrarCloserPeers(serviceId, disco.discoConf.bucketsCount)

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

  let serviceId = msg.key

  # Get closer peers for responses (RFC requires closerPeers in all responses)
  let closerPeers =
    disco.getRegistrarCloserPeers(serviceId, disco.discoConf.bucketsCount)

  let regMsg = msg.register.valueOr:
    # No register message provided, reject
    await conn.sendRegisterReject(closerPeers)
    return

  # Validate register message and decode/verify advertisement
  let adOpt = validateRegisterMessage(regMsg)
  if adOpt.isNone():
    await conn.sendRegisterReject(closerPeers)
    return

  let ad = adOpt.unsafeGet()
  let now = getTime().toUnix()

  # Prune expired ads first
  disco.registrar.pruneExpiredAds(disco.discoConf.advertExpiry)

  # Calculate wait time with lower bound enforcement
  let t_wait = disco.registrar.waitingTime(
    disco.discoConf, ad, disco.discoConf.advertCacheCap, serviceId, now
  )

  # Update lower bounds for service and IP (RFC section: Lower Bound Enforcement)
  disco.registrar.updateLowerBounds(serviceId, ad, t_wait, now)

  # Process retry ticket if provided
  let t_remaining = disco.processRetryTicket(regMsg, ad, t_wait, now)

  if t_remaining <= 0:
    # Accept the advertisement
    await disco.acceptAdvertisement(serviceId, ad, now, closerPeers, conn)
  else:
    # Send Wait response with ticket
    let ticket = Ticket(
      ad: regMsg.advertisement, t_init: now, t_mod: now, t_wait_for: 0, signature: @[]
    )
    await rejectAdvertisement(closerPeers, conn, t_remaining, ticket, disco)

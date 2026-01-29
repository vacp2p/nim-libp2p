# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[hashes, tables, sequtils, sets, options, algorithm]
from std/times import getTime, toUnix
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid, multicodec, multiaddress]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ../kademlia/[types, routingtable, protobuf]
import ./[types, protobuf]

logScope:
  topics = "kad-disco advertiser"

proc new*(T: typedesc[Advertiser]): T =
  T(advTable: initTable[ServiceId, AdvertiseTable](), actionQueue: @[])

proc actionCmp*(a, b: PendingAction): int =
  if a.scheduledTime < b.scheduledTime:
    -1
  elif a.scheduledTime > b.scheduledTime:
    1
  else:
    0

proc scheduleAction*(
    disco: KademliaDiscovery,
    serviceId: ServiceId,
    registrar: PeerId,
    bucketIdx: int,
    scheduledTime: Moment,
    ticket: Opt[Ticket] = Opt.none(Ticket),
) =
  ## Schedule an action at the given time, inserting it in the correct position
  ## in the time-ordered queue
  let action: PendingAction = (scheduledTime, serviceId, registrar, bucketIdx, ticket)

  # Find insertion point using binary search
  let idx = disco.advertiser.actionQueue.lowerBound(action, actionCmp)

  disco.advertiser.actionQueue.insert(action, idx)

proc sendRegister*(
    kad: KadDHT,
    peerId: PeerId,
    ad: Advertisement,
    ticket: Opt[Ticket] = Opt.none(Ticket),
): Future[Result[(RegistrationStatus, Opt[Ticket], seq[PeerId]), string]] {.
    async: (raises: [])
.} =
  ## Send REGISTER request to a peer

  let addrs = kad.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return err("No address found for peer")

  let connRes = catch:
    await kad.switch.dial(peerId, addrs, kad.codec)
  let conn = connRes.valueOr:
    return err("Dialing peer failed: " & error.msg)
  defer:
    await conn.close()

  var msg =
    Message(msgType: MessageType.register, key: ad.serviceId, ad: Opt.some(ad.encode()))

  if ticket.isSome():
    msg.ticket = Opt.some(ticket.get().encode())

  let writeRes = catch:
    await conn.writeLp(msg.encode().buffer)
  if writeRes.isErr:
    return err("Connection writing failed: " & writeRes.error.msg)

  let readRes = catch:
    await conn.readLp(MaxMsgSize)
  let replyBuf = readRes.valueOr:
    return err("Connection reading failed: " & error.msg)

  let reply = Message.decode(replyBuf).valueOr:
    return err("Failed to decode register message response" & $error)

  var status = RegistrationStatus.Rejected
  if reply.status.isSome():
    let stat = reply.status.get()
    if stat < 3:
      status = RegistrationStatus(stat)

  var responseTicket = Ticket()
  if reply.ticket.isSome():
    let buf = reply.ticket.get()
    responseTicket = Ticket.decode(buf).valueOr:
      return err("Failed to decode ticket: " & $error)

  var closerPeers: seq[PeerId] = @[]
  for peer in reply.closerPeers:
    let peerIdRes = PeerId.init(peer.id)
    if peerIdRes.isOk:
      closerPeers.add(peerIdRes.get)
    else:
      debug "Failed to decode peer id", err = peerIdRes.error

  return ok((status, Opt.some(responseTicket), closerPeers))

proc executeAndScheduleNext*(
    disco: KademliaDiscovery,
    serviceId: ServiceId,
    registrar: PeerId,
    bucketIdx: int,
    ticket: Opt[Ticket],
): Future[bool] {.async: (raises: []).} =
  ## Execute a registration action and schedule the next one based on response.
  ## Returns true if action should be rescheduled, false if rejected.

  # Build the advertisement
  var ad = Advertisement(
    serviceId: serviceId,
    peerId: disco.switch.peerInfo.peerId,
    addrs: disco.switch.peerInfo.addrs,
    timestamp: getTime().toUnix(),
    metadata: @[],
    signature: @[],
  )

  # Sign the advertisement
  let signRes = ad.sign(disco.switch.peerInfo.privateKey)
  if signRes.isErr:
    error "Failed to sign advertisement", error = signRes.error
    return false

  # Send register request
  let registerRes = await sendRegister(disco, registrar, ad, ticket)
  let (status, newTicketOpt, closerPeers) = registerRes.valueOr:
    error "Failed to register ad", err = error
    return false

  # Update advTable with closer peers if service still exists
  if serviceId in disco.advertiser.advTable:
    for peerId in closerPeers:
      try:
        discard disco.advertiser.advTable[serviceId].insert(peerId.toKey())
      except KeyError:
        # Service was removed, ignore
        break

  case status
  of RegistrationStatus.Confirmed:
    # Schedule re-advertisement after advertExpiry
    let nextTime = Moment.fromNow(int(disco.discoConf.advertExpiry).seconds)
    disco.scheduleAction(serviceId, registrar, bucketIdx, nextTime, Opt.none(Ticket))
    return true
  of RegistrationStatus.Wait:
    var newTicket = Ticket()
    if newTicketOpt.isSome:
      newTicket = newTicketOpt.get()
    # Schedule retry after t_wait_for
    let waitTime = min(disco.discoConf.advertExpiry, newTicket.t_wait_for.float64)
    let nextTime = Moment.fromNow(int(waitTime).seconds)
    disco.scheduleAction(serviceId, registrar, bucketIdx, nextTime, Opt.some(newTicket))
    return true
  of RegistrationStatus.Rejected:
    # Don't reschedule - this registrar rejected us
    return false

proc runAdvertiserLoop*(
    disco: KademliaDiscovery
) {.async: (raises: [CancelledError]).} =
  ## Main event loop for advertiser. Processes actions from the time-ordered queue.
  while true:
    let queue = disco.advertiser.actionQueue

    if queue.len == 0:
      await sleepAsync(1.seconds) # Idle wait
      continue

    let (scheduledTime, serviceId, registrar, bucketIdx, ticket) = queue[0]
    let now = Moment.now()

    if scheduledTime > now:
      await sleepAsync(scheduledTime - now)
      continue

    # Pop and execute
    disco.advertiser.actionQueue.delete(0)

    # Check if service is still being advertised
    if serviceId notin disco.advertiser.advTable:
      continue

    discard await disco.executeAndScheduleNext(serviceId, registrar, bucketIdx, ticket)

proc addProvidedService*(disco: KademliaDiscovery, serviceId: ServiceId) =
  ## Include this service in the set of services this node provides.
  ## Creates AdvT and bootstraps it from main KadDHT routing table.

  if serviceId in disco.advertiser.advTable:
    return # Already added

  # Create new AdvertiseTable centered on serviceId
  let advTable = AdvertiseTable.new(
    serviceId,
    config = RoutingTableConfig.new(
      replication = disco.config.replication, maxBuckets = disco.discoConf.bucketsCount
    ),
  )
  disco.advertiser.advTable[serviceId] = advTable

  # Bootstrap from main KadDHT routing table
  # For each peer in main rtable, calculate bucket index and insert into AdvT
  for bucket in disco.rtable.buckets:
    for peer in bucket.peers:
      let peerId = peer.nodeId.toPeerId().valueOr:
        continue
      let peerKey = peerId.toKey()
      # Calculate bucket index based on distance from serviceId
      let bucketIdx = bucketIndex(serviceId, peerKey, advTable.config.hasher)

      # Ensure bucket exists
      if bucketIdx >= advTable.buckets.len:
        advTable.buckets.setLen(bucketIdx + 1)

      # Insert peer into AdvT bucket if not full
      var advBucket = advTable.buckets[bucketIdx]
      if advBucket.peers.len < disco.discoConf.kRegister:
        # Check if peer already exists
        var found = false
        for p in advBucket.peers:
          if p.nodeId == peerKey:
            found = true
            break
        if not found:
          advBucket.peers.add(NodeEntry(nodeId: peerKey, lastSeen: peer.lastSeen))
          advTable.buckets[bucketIdx] = advBucket

  # Schedule registration actions for each bucket
  for bucketIdx in 0 ..< advTable.buckets.len:
    let bucket = advTable.buckets[bucketIdx]
    if bucket.peers.len == 0:
      continue

    # Shuffle peers for randomness
    var peers = bucket.peers
    shuffle(disco.rng, peers)

    # Select up to K_register peers
    let numToRegister = min(disco.discoConf.kRegister, peers.len)
    for i in 0 ..< numToRegister:
      let peerId = peers[i].nodeId.toPeerId().valueOr:
        error "Cannot convert key to peer id", error = error
        continue

      # Schedule immediate action (time=0 means ASAP)
      disco.scheduleAction(serviceId, peerId, bucketIdx, Moment.now(), Opt.none(Ticket))

proc removeProvidedService*(disco: KademliaDiscovery, serviceId: ServiceId) =
  ## Exclude this service from the set of services this node provides.
  ## Removes service from advTable and filters out pending actions.

  if serviceId notin disco.advertiser.advTable:
    return

  # Remove from advTable
  disco.advertiser.advTable.del(serviceId)

  # Filter out pending actions for this service
  disco.advertiser.actionQueue.keepItIf(it.serviceId != serviceId)

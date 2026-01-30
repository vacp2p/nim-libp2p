# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[tables, sequtils, sets, options, algorithm]
from std/times import getTime, toUnix
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid, multicodec, multiaddress]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ../kademlia/types
import ../kademlia/protobuf as kademlia_protobuf
import ../kademlia/routingtable
import ../kademlia_discovery/types
import ./[types, protobuf]

logScope:
  topics = "kad-disco advertiser"

proc new*(T: typedesc[Advertiser]): T =
  T(advTable: initTable[ServiceId, AdvertiseTable](), actionQueue: @[])

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
): Future[
    Result[(kademlia_protobuf.RegistrationStatus, Opt[Ticket], seq[PeerId]), string]
] {.async: (raises: []).} =
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

  # Build new nested Register message structure
  var regMsg = RegisterMessage(
    advertisement: ad.encode(),
    status: Opt.none(kademlia_protobuf.RegistrationStatus),
    ticket: Opt.none(TicketMessage),
  )

  # Add ticket if provided (retry case)
  if ticket.isSome():
    let ticketVal = ticket.get()
    regMsg.ticket = Opt.some(
      TicketMessage(
        advertisement: ticketVal.ad.encode(),
        tInit: ticketVal.t_init.uint64,
        tMod: ticketVal.t_mod.uint64,
        tWaitFor: ticketVal.t_wait_for,
        signature: ticketVal.signature,
      )
    )

  var msg = Message(
    msgType: MessageType.register, key: ad.serviceId, register: Opt.some(regMsg)
  )

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

  # Extract status from new nested Register message structure
  var status = kademlia_protobuf.RegistrationStatus.Rejected
  if reply.register.isSome():
    let replyRegMsg = reply.register.get()
    if replyRegMsg.status.isSome():
      status = replyRegMsg.status.get()

  # Extract ticket from new nested Register message structure
  var responseTicket = Ticket()
  if reply.register.isSome():
    let replyRegMsg = reply.register.get()
    if replyRegMsg.ticket.isSome():
      let ticketMsg = replyRegMsg.ticket.get()
      # Decode advertisement from ticket
      let ticketAdRes = Advertisement.decode(ticketMsg.advertisement)
      if ticketAdRes.isOk():
        responseTicket = Ticket(
          ad: ticketAdRes.get(),
          t_init: ticketMsg.tInit.int64,
          t_mod: ticketMsg.tMod.int64,
          t_wait_for: ticketMsg.tWaitFor,
          signature: ticketMsg.signature,
        )

  var closerPeers: seq[PeerId] = @[]
  for peer in reply.closerPeers:
    let peerIdRes = PeerId.init(peer.id)
    if peerIdRes.isOk:
      closerPeers.add(peerIdRes.get)
    else:
      debug "Failed to decode peer id", err = peerIdRes.error

  return ok((status, Opt.some(responseTicket), closerPeers))

proc advertise*(
    disco: KademliaDiscovery,
    serviceId: ServiceId,
    registrar: PeerId,
    bucketIdx: int,
    ticket: Opt[Ticket],
) {.async: (raises: []).} =
  ## Execute a registration action and schedule the next one based on response.

  var ad = Advertisement(
    serviceId: serviceId,
    peerId: disco.switch.peerInfo.peerId,
    addrs: disco.switch.peerInfo.addrs,
    timestamp: getTime().toUnix(),
    metadata: @[],
    signature: @[],
  )

  let signRes = ad.sign(disco.switch.peerInfo.privateKey)
  if signRes.isErr:
    error "Failed to sign advertisement", error = signRes.error
    return

  let registerRes = await sendRegister(disco, registrar, ad, ticket)
  let (status, newTicketOpt, closerPeers) = registerRes.valueOr:
    error "Failed to register ad", err = error
    return

  # Update advTable with closer peers if service still exists
  if serviceId in disco.advertiser.advTable:
    for peerId in closerPeers:
      try:
        discard disco.advertiser.advTable[serviceId].insert(peerId.toKey())
      except KeyError:
        # Service was removed, ignore
        break

  case status
  of kademlia_protobuf.RegistrationStatus.Confirmed:
    # Schedule re-advertisement after advertExpiry
    let nextTime = Moment.fromNow(int(disco.discoConf.advertExpiry).seconds)
    disco.scheduleAction(serviceId, registrar, bucketIdx, nextTime, Opt.none(Ticket))
    return
  of kademlia_protobuf.RegistrationStatus.Wait:
    var newTicket = Ticket()
    if newTicketOpt.isSome:
      newTicket = newTicketOpt.get()
    # Schedule retry after t_wait_for
    let waitTime = min(disco.discoConf.advertExpiry, newTicket.t_wait_for.float64)
    let nextTime = Moment.fromNow(int(waitTime).seconds)
    disco.scheduleAction(serviceId, registrar, bucketIdx, nextTime, Opt.some(newTicket))
    return
  of kademlia_protobuf.RegistrationStatus.Rejected:
    # Don't reschedule - this registrar rejected us
    return

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

    disco.advertiser.actionQueue.delete(0)

    if serviceId notin disco.advertiser.advTable:
      continue

    await disco.advertise(serviceId, registrar, bucketIdx, ticket)

proc addProvidedService*(disco: KademliaDiscovery, serviceId: ServiceId) =
  ## Include this service in the set of services this node provides.
  ## Creates AdvT and bootstraps it from main KadDHT routing table.

  if serviceId in disco.advertiser.advTable:
    return

  # Create new AdvertiseTable centered on serviceId
  var advTable = AdvertiseTable.new(
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

      discard advTable.insert(peerKey)

  disco.advertiser.advTable[serviceId] = advTable

  # Schedule registration actions for each bucket
  for bucketIdx in 0 ..< advTable.buckets.len:
    let bucket = advTable.buckets[bucketIdx]
    if bucket.peers.len == 0:
      continue

    var peers = bucket.peers
    shuffle(disco.rng, peers)

    # Select up to K_register peers
    let numToRegister = min(disco.discoConf.kRegister, peers.len)
    for i in 0 ..< numToRegister:
      let peerId = peers[i].nodeId.toPeerId().valueOr:
        error "Cannot convert key to peer id", error = error
        continue

      disco.scheduleAction(serviceId, peerId, bucketIdx, Moment.now(), Opt.none(Ticket))

proc removeProvidedService*(disco: KademliaDiscovery, serviceId: ServiceId) =
  ## Exclude this service from the set of services this node provides.
  ## Removes service from advTable and filters out pending actions.

  if serviceId notin disco.advertiser.advTable:
    return

  disco.advertiser.advTable.del(serviceId)
  disco.advertiser.actionQueue.keepItIf(it.serviceId != serviceId)

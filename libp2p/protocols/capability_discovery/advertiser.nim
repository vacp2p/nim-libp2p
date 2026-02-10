# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, sets, options, algorithm, times]
import chronos, chronicles, results
import
  ../../[peerid, switch, multihash, cid, multicodec, multiaddress, extended_peer_record]
import ../../crypto/crypto
import ../kademlia
import ../kademlia/types
import ../kademlia/protobuf
import ../kademlia_discovery/types
import ./[types, serviceroutingtables]

logScope:
  topics = "cap-disco advertiser"

proc new*(T: typedesc[Advertiser]): T =
  T(actionQueue: @[])

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
    kad: KademliaDiscovery,
    peerId: PeerId,
    serviceId: ServiceId,
    ad: seq[byte],
    ticket: Opt[Ticket] = Opt.none(Ticket),
): Future[Result[(protobuf.RegistrationStatus, Opt[Ticket], seq[PeerId]), string]] {.
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

  var regMsg = RegisterMessage(
    advertisement: ad,
    status: Opt.none(protobuf.RegistrationStatus),
    ticket: Opt.none(TicketMessage),
  )

  # Add ticket if provided (retry case)
  if ticket.isSome():
    let ticketVal = ticket.get()
    regMsg.ticket = Opt.some(
      TicketMessage(
        advertisement: ticketVal.ad,
        tInit: ticketVal.t_init.uint64,
        tMod: ticketVal.t_mod.uint64,
        tWaitFor: ticketVal.t_wait_for,
        signature: ticketVal.signature,
      )
    )

  var msg =
    Message(msgType: MessageType.register, key: serviceId, register: Opt.some(regMsg))

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

  var status = protobuf.RegistrationStatus.Rejected

  var responseTicket = Ticket()
  if reply.register.isSome():
    let replyRegMsg = reply.register.get()

    if replyRegMsg.status.isSome():
      status = replyRegMsg.status.get()

    if replyRegMsg.ticket.isSome():
      let ticketMsg = replyRegMsg.ticket.get()

      responseTicket = Ticket(
        ad: ticketMsg.advertisement,
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
    ad: Advertisement,
    registrar: PeerId,
    bucketIdx: int,
    ticket: Opt[Ticket],
) {.async: (raises: []).} =
  ## Execute a registration action and schedule the next one based on response.

  let adBuf: seq[byte] = ad.encode().valueOr:
    error "Failed to encode ad", error
    return

  let registerRes = await disco.sendRegister(registrar, serviceId, adBuf, ticket)
  let (status, newTicketOpt, closerPeers) = registerRes.valueOr:
    error "Failed to register ad", err = error
    return

  # Update service routing table with closer peers if service still exists
  for peerId in closerPeers:
    disco.serviceRoutingTables.insertPeer(serviceId, peerId.toKey())

  case status
  of protobuf.RegistrationStatus.Confirmed:
    # Schedule re-advertisement after advertExpiry
    let nextTime = Moment.now() + chronos.seconds(int(disco.discoConf.advertExpiry))
    disco.scheduleAction(serviceId, registrar, bucketIdx, nextTime, Opt.none(Ticket))
    return
  of protobuf.RegistrationStatus.Wait:
    var newTicket = Ticket()
    if newTicketOpt.isSome:
      newTicket = newTicketOpt.get()
    # Schedule retry after t_wait_for
    let waitTime = min(disco.discoConf.advertExpiry, newTicket.t_wait_for.float64)
    let nextTime = Moment.now() + chronos.seconds(int(waitTime))
    disco.scheduleAction(serviceId, registrar, bucketIdx, nextTime, Opt.some(newTicket))
    return
  of protobuf.RegistrationStatus.Rejected:
    # Don't reschedule - this registrar rejected us
    return

proc runAdvertiseLoop*(disco: KademliaDiscovery) {.async: (raises: [CancelledError]).} =
  ## Main event loop for advertiser. Processes actions from the time-ordered queue.

  while true:
    let queue = disco.advertiser.actionQueue

    if queue.len == 0:
      await sleepAsync(chronos.seconds(1)) # Idle wait
      continue

    let (scheduledTime, serviceId, registrar, bucketIdx, ticket) = queue[0]
    let now = Moment.now()

    if scheduledTime > now:
      await sleepAsync(scheduledTime - now)
      continue

    disco.advertiser.actionQueue.delete(0)

    if not disco.serviceRoutingTables.hasService(serviceId):
      continue

    # Create a SignedExtendedPeerRecord for this node
    let updateRes = catch:
      await disco.switch.peerInfo.update()
    if updateRes.isErr:
      error "Failed to update peer info", err = updateRes.error.msg
      continue

    let
      peerInfo: PeerInfo = disco.switch.peerInfo
      services: seq[ServiceInfo] = disco.services.toSeq()

    let ad = SignedExtendedPeerRecord.init(
      peerInfo.privateKey,
      ExtendedPeerRecord(
        peerId: peerInfo.peerId,
        seqNo: getTime().toUnix().uint64,
        addresses: peerInfo.addrs.mapIt(AddressInfo(address: it)),
        services: services,
      ),
    ).valueOr:
      error "Failed to create signed peer record", error = $error
      continue

    await disco.advertise(serviceId, ad, registrar, bucketIdx, ticket)

proc addProvidedService*(disco: KademliaDiscovery, serviceId: ServiceId) =
  ## Include this service in the set of services this node provides.
  ## Creates AdvT and bootstraps it from main KadDHT routing table.

  disco.serviceRoutingTables.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConf.bucketsCount
  )

  let advTable = disco.serviceRoutingTables.getTable(serviceId).valueOr:
    error "service not found"
    return

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

  disco.serviceRoutingTables.removeService(serviceId)
  disco.advertiser.actionQueue.keepItIf(it.serviceId != serviceId)

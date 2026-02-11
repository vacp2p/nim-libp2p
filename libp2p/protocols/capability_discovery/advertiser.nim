# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, algorithm]
import chronos, chronicles, results
import
  ../../[peerid, switch, multihash, cid, multicodec, multiaddress, extended_peer_record]
import ../../crypto/crypto
import ../kademlia
import ../kademlia/[types, protobuf]
import ../kademlia_discovery/types
import ./[types, serviceroutingtables]

logScope:
  topics = "cap-disco advertiser"

proc runAdvertiseLoop*(disco: KademliaDiscovery) {.async: (raises: [CancelledError]).}

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
  ## Schedule an action at the given time

  let action: PendingAction = (scheduledTime, serviceId, registrar, bucketIdx, ticket)
  let idx = disco.advertiser.actionQueue.lowerBound(action, actionCmp)
  disco.advertiser.actionQueue.insert(action, idx)

proc processAction*(disco: KademliaDiscovery) =
  ## Start processing scheduled actions

  if disco.advertiseLoop.isNil and disco.advertiser.actionQueue.len > 0:
    disco.advertiseLoop = disco.runAdvertiseLoop()

proc scheduleAndProcessAction*(
    disco: KademliaDiscovery,
    serviceId: ServiceId,
    registrar: PeerId,
    bucketIdx: int,
    scheduledTime: Moment,
    ticket: Opt[Ticket] = Opt.none(Ticket),
) =
  disco.scheduleAction(serviceId, registrar, bucketIdx, scheduledTime, ticket)

  disco.processAction()

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
    return err("no address found for peer: " & $peerId)

  let connRes = catch:
    await kad.switch.dial(peerId, addrs, kad.codec)
  let conn = connRes.valueOr:
    return err("dialing peer failed: " & error.msg)
  defer:
    await conn.close()

  var regMsg = RegisterMessage(
    advertisement: ad, status: Opt.none(protobuf.RegistrationStatus), ticket: ticket
  )

  var msg =
    Message(msgType: MessageType.register, key: serviceId, register: Opt.some(regMsg))

  let writeRes = catch:
    await conn.writeLp(msg.encode().buffer)
  if writeRes.isErr:
    return err("connection writing failed: " & writeRes.error.msg)

  let readRes = catch:
    await conn.readLp(MaxMsgSize)
  let replyBuf = readRes.valueOr:
    return err("connection reading failed: " & error.msg)

  let reply = Message.decode(replyBuf).valueOr:
    return err("failed to decode register message response" & $error)

  var closerPeers: seq[PeerId] = @[]
  for peer in reply.closerPeers:
    let peerId = PeerId.init(peer.id).valueOr:
      error "failed to decode peer id", error
      continue

    closerPeers.add(peerId)

  let registerMsg = reply.register.valueOr:
    return err("register reply not found")

  let status = registerMsg.status.valueOr:
    return err("register reply status not found")

  return ok((status, registerMsg.ticket, closerPeers))

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
    error "failed to encode ad", error
    return

  let (status, newTicketOpt, closerPeers) = (
    await disco.sendRegister(registrar, serviceId, adBuf, ticket)
  ).valueOr:
    error "failed to register ad", error
    return

  for peerId in closerPeers:
    disco.serviceRoutingTables.insertPeer(serviceId, peerId.toKey())

  case status
  of protobuf.RegistrationStatus.Confirmed:
    let nextTime = Moment.now() + chronos.seconds(int(disco.discoConf.advertExpiry))
    disco.scheduleAction(serviceId, registrar, bucketIdx, nextTime, Opt.none(Ticket))
  of protobuf.RegistrationStatus.Wait:
    let newTicket = newTicketOpt.valueOr:
      error "no ticket to retry with"
      return

    let waitTime = min(disco.discoConf.advertExpiry, newTicket.tWaitFor.float64)
    let nextTime = Moment.now() + chronos.seconds(int(waitTime))
    disco.scheduleAction(serviceId, registrar, bucketIdx, nextTime, Opt.some(newTicket))
  of protobuf.RegistrationStatus.Rejected:
    # Don't reschedule - this registrar rejected us
    return

  disco.processAction()

proc addProvidedService*(disco: KademliaDiscovery, serviceId: ServiceId) =
  ## Include this service in the set of services this node provides.

  disco.serviceRoutingTables.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConf.bucketsCount
  )

  let advTable = disco.serviceRoutingTables.getTable(serviceId).valueOr:
    error "service not found", serviceId
    return

  for bucketIdx in 0 ..< advTable.buckets.len:
    let bucket = advTable.buckets[bucketIdx]
    if bucket.peers.len == 0:
      continue

    var peers = bucket.peers
    shuffle(disco.rng, peers)

    let numToRegister = min(disco.discoConf.kRegister, peers.len)
    for i in 0 ..< numToRegister:
      let peerId = peers[i].nodeId.toPeerId().valueOr:
        error "cannot convert key to peer id", error
        continue

      disco.scheduleAction(serviceId, peerId, bucketIdx, Moment.now(), Opt.none(Ticket))

  disco.processAction()

proc removeProvidedService*(disco: KademliaDiscovery, serviceId: ServiceId) =
  ## Exclude this service from the set of services this node provides.

  disco.serviceRoutingTables.removeService(serviceId)
  disco.advertiser.actionQueue.keepItIf(it.serviceId != serviceId)

proc runAdvertiseLoop*(disco: KademliaDiscovery) {.async: (raises: [CancelledError]).} =
  ## Loop through all pre-scheduled actions and execute them at the correct time.

  while true:
    let queue = disco.advertiser.actionQueue

    if queue.len == 0:
      # The loop is restarted lazily by processAction()
      return

    let (scheduledTime, serviceId, registrar, bucketIdx, ticket) = queue[0]
    let now = Moment.now()

    if scheduledTime > now:
      await sleepAsync(scheduledTime - now)

    disco.advertiser.actionQueue.delete(0)

    if not disco.serviceRoutingTables.hasService(serviceId):
      error "no service routing table found", serviceId
      continue

    let record = (await disco.record()).valueOr:
      error "failed create extended peer record", error
      continue

    await disco.advertise(serviceId, record, registrar, bucketIdx, ticket)

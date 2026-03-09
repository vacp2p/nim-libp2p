# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sets, sequtils]
import chronos, chronicles, results
import
  ../../[peerid, switch, multihash, cid, multicodec, multiaddress, extended_peer_record]
import ../../crypto/crypto
import ../kademlia
import ../kademlia/[types, protobuf]
import ../kademlia_discovery/types
import ./[types, serviceroutingtables, capability_discovery_metrics]

logScope:
  topics = "cap-disco advertiser"

proc new*(T: typedesc[Advertiser]): T =
  T(running: initHashSet[ptr AdvertiseTask]())

proc clear*(a: Advertiser) =
  for p in a.running:
    let f = cast[Future[void]](p)
    if not f.finished:
      f.cancel()
  a.running.clear()

proc sendRegister*(
    disco: KademliaDiscovery,
    peerId: PeerId,
    serviceId: ServiceId,
    ad: seq[byte],
    ticket: Opt[Ticket] = Opt.none(Ticket),
): Future[Result[(protobuf.RegistrationStatus, Opt[Ticket], seq[PeerId]), string]] {.
    async: (raises: [CancelledError])
.} =
  ## Send REGISTER request to a peer

  let addrs = disco.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return err("no address found for peer: " & $peerId)

  let connRes = catch:
    await disco.switch.dial(peerId, addrs, disco.codec)
  let conn = connRes.valueOr:
    return err("dialing peer failed: " & error.msg)
  defer:
    await conn.close()

  var regMsg = RegisterMessage(
    advertisement: ad, status: Opt.none(protobuf.RegistrationStatus), ticket: ticket
  )

  var msg =
    Message(msgType: MessageType.register, key: serviceId, register: Opt.some(regMsg))

  let encodedMsg = msg.encode().buffer

  cd_messages_sent.inc(labelValues = [$MessageType.register])
  cd_message_bytes_sent.inc(
    encodedMsg.len.float64, labelValues = [$MessageType.register]
  )

  var writeRes: Result[void, ref CatchableError]
  var readRes: Result[seq[byte], ref CatchableError]
  cd_message_duration_ms.time(labelValues = [$MessageType.register]):
    writeRes = catch:
      await conn.writeLp(encodedMsg)
    readRes = catch:
      await conn.readLp(MaxMsgSize)

  if writeRes.isErr:
    return err("connection writing failed: " & writeRes.error.msg)
  let replyBuf = readRes.valueOr:
    return err("connection reading failed: " & readRes.error.msg)

  cd_messages_received.inc(labelValues = [$MessageType.register])
  cd_message_bytes_received.inc(
    replyBuf.len.float64, labelValues = [$MessageType.register]
  )

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

  cd_register_responses.inc(labelValues = [$status])

  return ok((status, registerMsg.ticket, closerPeers))

proc startAdvertising*(
    disco: KademliaDiscovery,
    serviceId: ServiceId,
    registrar: PeerId,
    bucketIdx: int,
    ticket: Opt[Ticket],
) {.async: (raises: [CancelledError]).} =
  ## Execute a registration action and schedule the next one based on response.

  if not disco.serviceRoutingTables.hasService(serviceId):
    error "no service routing table found", serviceId
    return

  let record = (await disco.record()).valueOr:
    error "failed create extended peer record", error
    return

  cd_advertiser_actions_executed.inc()

  let adBuf: seq[byte] = record.encode().valueOr:
    error "failed to encode ad", error
    return

  var currentTicket = ticket

  while true:
    let (status, newTicketOpt, closerPeers) = (
      await disco.sendRegister(registrar, serviceId, adBuf, currentTicket)
    ).valueOr:
      error "failed to register ad", error
      return

    for peerId in closerPeers:
      disco.serviceRoutingTables.insertPeer(serviceId, peerId.toKey())

    case status
    of protobuf.RegistrationStatus.Confirmed:
      await sleepAsync(chronos.seconds(int(disco.discoConf.advertExpiry)))
    of protobuf.RegistrationStatus.Wait:
      let newTicket = newTicketOpt.valueOr:
        error "no ticket to retry with"
        return

      currentTicket = Opt.some(newTicket)

      await sleepAsync(
        chronos.seconds(
          int(min(disco.discoConf.advertExpiry, newTicket.tWaitFor.float64))
        )
      )
    of protobuf.RegistrationStatus.Rejected:
      # Don't reschedule - this registrar rejected us
      break

proc addProvidedService*(disco: KademliaDiscovery, service: ServiceInfo) =
  ## Include this service in the set of services this node provides.

  let serviceId = service.id.hashServiceId()

  if disco.serviceRoutingTables.hasService(serviceId):
    debug "skipping adding service", id = serviceId
    return

  disco.serviceRoutingTables.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConf.bucketsCount,
    Provided,
  )

  cd_advertiser_services_added.inc()

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
      let registrar = peers[i].nodeId.toPeerId().valueOr:
        error "cannot convert key to peer id", error
        continue

      let fut =
        disco.startAdvertising(serviceId, registrar, bucketIdx, Opt.none(Ticket))
      let task = AdvertiseTask(fut: fut, serviceId: serviceId)
      disco.advertiser.running.incl cast[ptr AdvertiseTask](addr task)

  disco.services.incl(service)

proc removeProvidedService*(disco: KademliaDiscovery, service: ServiceInfo) =
  let serviceId = service.id.hashServiceId()

  # cancel and remove futures for this service
  for p in toSeq(disco.advertiser.running):
    let t = cast[ptr AdvertiseTask](p)
    if t.serviceId == serviceId:
      if not t.fut.finished:
        t.fut.cancel()
      disco.advertiser.running.excl p

  # remove service from tables
  disco.serviceRoutingTables.removeService(serviceId, Provided)
  disco.services.excl(service)
  cd_advertiser_services_removed.inc()

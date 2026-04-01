# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sets]
import chronos, chronicles, results
import
  ../../[peerid, switch, multihash, cid, multicodec, multiaddress, extended_peer_record]
import ../../crypto/crypto
import ../kademlia
import ../kademlia/[types, protobuf]
import ../kademlia_discovery/types
import ./[types, serviceroutingtables, service_discovery_metrics]

logScope:
  topics = "service-disco advertiser"

proc new*(T: typedesc[Advertiser]): T =
  T(running: initHashSet[AdvertiseTask]())

proc clear*(a: Advertiser) =
  for t in a.running:
    if not t.fut.finished:
      t.fut.cancel()
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
    add: Opt[seq[byte]],
) {.async: (raises: [CancelledError]).} =
  ## Execute a registration action and schedule the next one based on response.

  if disco.clientMode:
    error "client mode nodes cannot start advertising"
    return

  if not disco.serviceRoutingTables.hasService(serviceId):
    error "no service routing table found", serviceId
    return

  let addBuff =
    if add.isNone:
      let record = disco.record().valueOr:
        error "failed create extended peer record", error
        return

      let addBytes: seq[byte] = record.encode().valueOr:
        error "failed to encode ad", error
        return

      addBytes
    else:
      add.get()

  cd_advertiser_actions_executed.inc()

  var currentTicket = ticket

  while true:
    let (status, newTicketOpt, closerPeers) = (
      await disco.sendRegister(registrar, serviceId, addBuff, currentTicket)
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
          int(min(disco.discoConf.advertExpiry.uint32, newTicket.tWaitFor))
        )
      )
    of protobuf.RegistrationStatus.Rejected:
      # Don't reschedule - this registrar rejected us
      break

proc addProvidedService*(
    disco: KademliaDiscovery,
    service: ServiceInfo,
    add: Opt[seq[byte]] = Opt.none(seq[byte]),
) =
  ## Include this service in the set of services this node provides.

  if disco.clientMode:
    error "client mode nodes cannot advertise services"
    return

  let serviceId = service.id.hashServiceId()

  let isNew = disco.serviceRoutingTables.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConf.bucketsCount,
    Provided,
  )

  disco.services.incl(service)
  cd_advertiser_services_added.inc()

  if not isNew:
    return

  let advTable = disco.serviceRoutingTables.getTable(serviceId).valueOr:
    error "service not found", serviceId
    return

  for bucketIdx in 0 ..< advTable.buckets.len:
    let bucket = advTable.buckets[bucketIdx]
    if bucket.peers.len == 0:
      continue

    var peers = bucket.peers
    disco.rng.shuffle(peers)

    let numToRegister = min(disco.discoConf.kRegister, peers.len)
    debug "numtoregister",
      numToRegister = numToRegister,
      kRegister = disco.discoConf.kRegister,
      peersLen = peers.len
    for i in 0 ..< numToRegister:
      let registrar = peers[i].nodeId.toPeerId().valueOr:
        error "cannot convert key to peer id", error
        continue

      let fut =
        disco.startAdvertising(serviceId, registrar, bucketIdx, Opt.none(Ticket), add)
      disco.advertiser.running.incl AdvertiseTask(fut: fut, serviceId: serviceId)

proc removeProvidedService*(disco: KademliaDiscovery, service: ServiceInfo) =
  let serviceId = service.id.hashServiceId()

  # cancel and remove futures for this service
  var toRemove: seq[AdvertiseTask] = @[]
  for t in disco.advertiser.running:
    if t.serviceId == serviceId:
      if not t.fut.finished:
        t.fut.cancel()
      toRemove.add(t)
  for t in toRemove:
    disco.advertiser.running.excl t

  # remove service from tables
  disco.serviceRoutingTables.removeService(serviceId, Provided)
  disco.services.excl(service)
  cd_advertiser_services_removed.inc()

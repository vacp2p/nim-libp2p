# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sets, times, sequtils]
import chronos, chronicles, results
import
  ../../[peerid, switch, multihash, cid, multicodec, multiaddress, extended_peer_record]
import ../../crypto/crypto
import ../kademlia
import ../kademlia/[types, protobuf as kademlia_protobuf]
import ./[types, routing_table_manager, service_discovery_metrics]

logScope:
  topics = "service-disco advertiser"

proc clear*(a: Advertiser) =
  for t in a.running:
    if not t.fut.finished:
      t.fut.cancelSoon()
  a.running.clear()
  cd_advertiser_pending_actions.set(0)

proc sendRegister*(
    disco: ServiceDiscovery,
    peerId: PeerId,
    serviceId: ServiceId,
    ad: seq[byte],
    ticket: Opt[Ticket] = Opt.none(Ticket),
): Future[
    Result[(kademlia_protobuf.RegistrationStatus, Opt[Ticket], seq[PeerId]), string]
] {.async: (raises: [CancelledError]).} =
  let addrs = disco.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return err("no address found for peer: " & $peerId)

  let connRes = catch:
    await disco.switch.dial(peerId, addrs, disco.codec)
  let conn = connRes.valueOr:
    return err("dialing peer failed: " & error.msg)
  defer:
    await conn.close()

  let regMsg = RegisterMessage(
    advertisement: ad,
    status: Opt.none(kademlia_protobuf.RegistrationStatus),
    ticket: ticket,
  )
  let msg =
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
    return err("failed to decode register message response: " & $error)

  var closerPeers: seq[PeerId] = @[]
  for peer in reply.closerPeers:
    let pid = PeerId.init(peer.id).valueOr:
      error "failed to decode peer id", error
      continue
    closerPeers.add(pid)

  let registerMsg = reply.register.valueOr:
    return err("register reply not found")
  let status = registerMsg.status.valueOr:
    return err("register reply status not found")

  cd_register_responses.inc(labelValues = [$status])
  return ok((status, registerMsg.ticket, closerPeers))

proc startAdvertising*(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    registrar: PeerId,
    bucketIdx: int,
    ticket: Opt[Ticket],
    add: Opt[seq[byte]],
) {.async: (raises: [CancelledError]).} =
  if not disco.rtManager.hasService(serviceId):
    error "no service routing table found", serviceId
    return

  let addBuff =
    if add.isSome:
      add.get()
    else:
      let peerInfo = disco.switch.peerInfo
      let extRecord = SignedExtendedPeerRecord.init(
        peerInfo.privateKey,
        ExtendedPeerRecord(
          peerId: peerInfo.peerId,
          seqNo: getTime().toUnix().uint64,
          addresses: peerInfo.addrs.mapIt(AddressInfo(address: it)),
          services: disco.services.toSeq(),
        ),
      ).valueOr:
        error "failed to create extended peer record", error
        return
      extRecord.encode().valueOr:
        error "failed to encode advertisement", error
        return

  cd_advertiser_actions_executed.inc()

  var currentTicket = ticket

  while true:
    let (status, newTicketOpt, closerPeers) = (
      await disco.sendRegister(registrar, serviceId, addBuff, currentTicket)
    ).valueOr:
      error "failed to register ad", error
      return

    for pid in closerPeers:
      disco.rtManager.insertPeer(serviceId, pid.toKey())

    case status
    of kademlia_protobuf.RegistrationStatus.Confirmed:
      await sleepAsync(disco.discoConfig.advertExpiry)
    of kademlia_protobuf.RegistrationStatus.Wait:
      let newTicket = newTicketOpt.valueOr:
        error "no ticket to retry with"
        return
      currentTicket = Opt.some(newTicket)
      let waitSecs =
        min(disco.discoConfig.advertExpiry.seconds.uint32, newTicket.tWaitFor)
      await sleepAsync(chronos.seconds(int(waitSecs)))
    of kademlia_protobuf.RegistrationStatus.Rejected:
      break

proc addProvidedService*(
    disco: ServiceDiscovery,
    service: ServiceInfo,
    add: Opt[seq[byte]] = Opt.none(seq[byte]),
) {.async: (raises: [CancelledError]).} =
  let serviceId = service.id.hashServiceId()

  if not disco.rtManager.addService(
    serviceId, disco.rtable, disco.config.replication, disco.discoConfig.bucketsCount,
    Provided,
  ):
    return

  disco.services.incl(service)
  cd_advertiser_services_added.inc()

  let advTable = disco.rtManager.getTable(serviceId).valueOr:
    error "service not found", serviceId
    return

  for bucketIdx in 0 ..< advTable.buckets.len:
    let bucket = advTable.buckets[bucketIdx]
    if bucket.peers.len == 0:
      continue

    var peers = bucket.peers
    disco.rng.shuffle(peers)

    for i in 0 ..< min(disco.discoConfig.kRegister, peers.len):
      let registrar = peers[i].nodeId.toPeerId().valueOr:
        error "cannot convert key to peer id", error
        continue

      let fut =
        disco.startAdvertising(serviceId, registrar, bucketIdx, Opt.none(Ticket), add)
      disco.advertiser.running.incl(AdvertiseTask(fut: fut, serviceId: serviceId))
      cd_advertiser_pending_actions.inc()

proc removeProvidedService*(
    disco: ServiceDiscovery, service: ServiceInfo
) {.async: (raises: [CancelledError]).} =
  let serviceId = service.id.hashServiceId()

  var toRemove: seq[AdvertiseTask] = @[]
  for t in disco.advertiser.running:
    if t.serviceId == serviceId:
      if not t.fut.finished:
        await t.fut.cancelAndWait()
      toRemove.add(t)
  for t in toRemove:
    disco.advertiser.running.excl(t)
  cd_advertiser_pending_actions.set(disco.advertiser.running.len.float64)

  disco.rtManager.removeService(serviceId, Provided)
  disco.services.excl(service)
  cd_advertiser_services_removed.inc()

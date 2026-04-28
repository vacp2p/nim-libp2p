# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sets]
import chronos, chronicles, results
import
  ../../[peerid, switch, multihash, cid, multicodec, multiaddress, extended_peer_record]
import ../../crypto/crypto
import ../kademlia
import ../kademlia/[types, protobuf as kademlia_protobuf]
import ./[types, routing_table_manager, service_discovery_metrics]

logScope:
  topics = "service-disco advertiser"

type RegistrationResponse* = object
  status*: kademlia_protobuf.RegistrationStatus
  ticket*: Opt[Ticket]
  closerPeers*: seq[PeerInfo]

proc clear*(a: Advertiser) =
  for task in a.running:
    task.fut.cancelSoon()
  a.running.clear()
  cd_advertiser_pending_actions.set(0)

proc sendRegister*(
    disco: ServiceDiscovery,
    peerId: PeerId,
    serviceId: ServiceId,
    ad: seq[byte],
    ticket: Opt[Ticket] = Opt.none(Ticket),
): Future[Result[RegistrationResponse, string]] {.async: (raises: [CancelledError]).} =
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

  let registerMsg = reply.register.valueOr:
    return err("register reply not found")
  let status = registerMsg.status.valueOr:
    return err("register reply status not found")

  cd_register_responses.inc(labelValues = [$status])

  let closerPeers = reply.closerPeers.toPeerInfos()

  return ok(
    RegistrationResponse(
      status: status, ticket: registerMsg.ticket, closerPeers: closerPeers
    )
  )

proc advertiseToRegistrar*(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    registrar: PeerId,
    bucketIdx: int,
    ticket: Opt[Ticket],
    advert: Opt[seq[byte]],
) {.async: (raises: [CancelledError]).} =
  doAssert not disco.clientMode, "not supported in client mode"

  if not disco.rtManager.hasService(serviceId):
    error "no service routing table found", serviceId
    return

  let advertBuff = advert.valueOr:
    let extRecord = disco.record().valueOr:
      error "failed create extended peer record", error
      return
    extRecord.encode().valueOr:
      error "failed to encode advertisement", error
      return

  cd_advertiser_actions_executed.inc()

  var currentTicket = ticket

  while true:
    let response = (
      await disco.sendRegister(registrar, serviceId, advertBuff, currentTicket)
    ).valueOr:
      error "failed to register ad", error
      return

    disco.updatePeers(response.closerPeers)

    for p in response.closerPeers:
      disco.rtManager.insertPeer(serviceId, p.peerId.toKey())

    case response.status
    of kademlia_protobuf.RegistrationStatus.Confirmed:
      await sleepAsync(disco.discoConfig.advertExpiry)
    of kademlia_protobuf.RegistrationStatus.Wait:
      let newTicket = response.ticket.valueOr:
        error "no ticket to retry with"
        return

      currentTicket = Opt.some(newTicket)

      let waitSecs =
        min(disco.discoConfig.advertExpiry.seconds.uint32, newTicket.tWaitFor)

      await sleepAsync(chronos.seconds(int(waitSecs)))
    of kademlia_protobuf.RegistrationStatus.Rejected:
      # Don't reschedule - this registrar rejected us
      break

proc addProvidedService*(
    disco: ServiceDiscovery,
    service: ServiceInfo,
    advert: Opt[seq[byte]] = Opt.none(seq[byte]),
) =
  doAssert not disco.clientMode, "not supported in client mode"

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

  var tasksSpawned = false
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

      let fut = disco.advertiseToRegistrar(
        serviceId, registrar, bucketIdx, Opt.none(Ticket), advert
      )
      disco.advertiser.running.incl(AdvertiseTask(fut: fut, serviceId: serviceId))
      cd_advertiser_pending_actions.inc()
      tasksSpawned = true

  if not tasksSpawned:
    # The service routing table is empty because all peers from the main routing
    # table have a bucket index >= bucketsCount relative to the service ID in XOR
    # space (probability 1/2^bucketsCount per peer). Fall back to advertising
    # directly to peers from the main routing table so that the service is always
    # registered when there are known peers.
    var mainPeers: seq[NodeEntry]
    for bucket in disco.rtable.buckets:
      for peer in bucket.peers:
        mainPeers.add(peer)
    disco.rng.shuffle(mainPeers)
    for i in 0 ..< min(disco.discoConfig.kRegister, mainPeers.len):
      let registrar = mainPeers[i].nodeId.toPeerId().valueOr:
        error "cannot convert key to peer id", error
        continue
      # bucketIdx 0 is passed but is unused by advertiseToRegistrar
      let fut =
        disco.advertiseToRegistrar(serviceId, registrar, 0, Opt.none(Ticket), advert)
      disco.advertiser.running.incl(AdvertiseTask(fut: fut, serviceId: serviceId))
      cd_advertiser_pending_actions.inc()

proc removeProvidedService*(
    disco: ServiceDiscovery, serviceId: string
) {.async: (raises: [CancelledError]).} =
  doAssert not disco.clientMode, "not supported in client mode"

  let sid = serviceId.hashServiceId()

  var toRemove: HashSet[AdvertiseTask]

  for t in disco.advertiser.running.filterIt(it.serviceId == sid):
    await t.fut.cancelAndWait()
    toRemove.incl(t)

  disco.advertiser.running.excl(toRemove)
  cd_advertiser_pending_actions.set(disco.advertiser.running.len.float64)

  disco.rtManager.removeService(sid, Provided)
  for s in disco.services:
    if s.id == serviceId:
      disco.services.excl(s)
      break
  cd_advertiser_services_removed.inc()

proc startAdvertising*(
    disco: ServiceDiscovery,
    service: ServiceInfo,
    advert: Opt[seq[byte]] = Opt.none(seq[byte]),
) =
  disco.addProvidedService(service, advert = advert)

proc stopAdvertising*(
    disco: ServiceDiscovery, serviceId: string
) {.async: (raises: [CancelledError]).} =
  await disco.removeProvidedService(serviceId)

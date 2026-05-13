# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sets]
import chronos, chronicles, results
import
  ../../[peerid, switch, multihash, cid, multicodec, multiaddress, extended_peer_record]
import ../../crypto/crypto
import ../kademlia
import ../kademlia/[types, protobuf as kademlia_protobuf]
import
  ./[types, routing_table_manager, service_discovery_metrics, registrar, connection]

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

proc localRegister(disco: ServiceDiscovery, msg: Message): Result[Message, string] =
  return ok(disco.registration(msg))

proc sendRegister*(
    disco: ServiceDiscovery,
    peerId: PeerId,
    serviceId: ServiceId,
    ad: seq[byte],
    ticket: Opt[Ticket] = Opt.none(Ticket),
): Future[Result[RegistrationResponse, string]] {.async: (raises: [CancelledError]).} =
  let msg = Message(
    msgType: MessageType.register,
    key: serviceId,
    register: Opt.some(
      RegisterMessage(
        advertisement: ad,
        status: Opt.none(kademlia_protobuf.RegistrationStatus),
        ticket: ticket,
      )
    ),
  )

  let replyRes =
    if peerId == disco.switch.peerInfo.peerId:
      disco.localRegister(msg)
    else:
      await disco.send(peerId, msg)

  let reply = replyRes.valueOr:
    return err($error)

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

  debug "registering advert", serviceId, registrar

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
      debug "advert accepted", serviceId, registrar

      await sleepAsync(disco.discoConfig.advertExpiry)
    of kademlia_protobuf.RegistrationStatus.Wait:
      let newTicket = response.ticket.valueOr:
        error "no ticket to retry with"
        return

      currentTicket = Opt.some(newTicket)

      let waitSecs = min(disco.discoConfig.advertExpiry, newTicket.tWaitFor)

      debug "waiting for registrar", serviceId, registrar, wait = $waitSecs

      await sleepAsync(waitSecs)
    of kademlia_protobuf.RegistrationStatus.Rejected:
      # Don't reschedule - this registrar rejected us
      debug "registrar rejection, aborting", serviceId, registrar
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

  debug "added provided service", service = service.id, serviceId

  disco.services.incl(service)
  cd_advertiser_services_added.inc()

  let advTable = disco.rtManager.getTable(serviceId).valueOr:
    error "service not found", serviceId
    return

  # Remote advertising
  for bucket in advTable.buckets:
    if bucket.peers.len == 0:
      continue

    let peers = disco.rng.pick(bucket.peers, disco.discoConfig.kRegister).valueOr:
      continue

    for peer in peers:
      let registrar = peer.nodeId.toPeerId().valueOr:
        error "cannot convert key to peer id", error
        continue

      let fut =
        disco.advertiseToRegistrar(serviceId, registrar, Opt.none(Ticket), advert)
      disco.advertiser.running.incl(AdvertiseTask(fut: fut, serviceId: serviceId))
      cd_advertiser_pending_actions.inc()

  # Local advertising
  let fut = disco.advertiseToRegistrar(
    serviceId, disco.switch.peerInfo.peerId, Opt.none(Ticket), advert
  )
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

  debug "removed provided service", service = serviceId, serviceId = sid

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

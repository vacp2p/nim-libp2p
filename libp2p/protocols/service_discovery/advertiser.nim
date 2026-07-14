# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sets, tables, sequtils]
import chronos, chronicles, results
import ../../utils/heartbeat
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

proc clear*(a: Advertiser) {.async: (raises: []).} =
  var running = move a.running
  var runningFuts: seq[Future[void]]
  for task in running:
    runningFuts.add(task.fut)

  await runningFuts.cancelAndWait()

  a.providedAdverts = initTable[ServiceId, seq[byte]]()
  cd_advertiser_pending_actions.set(0)

proc cleanupFinishedTasks(a: Advertiser) =
  var toRemove: HashSet[AdvertiseTask]
  for t in a.running:
    if t.fut.finished:
      toRemove.incl(t)
  if toRemove.len > 0:
    a.running.excl(toRemove)
    cd_advertiser_pending_actions.set(a.running.len.float64)

proc getAdvertBytes(disco: ServiceDiscovery, explicit: Opt[seq[byte]]): Opt[seq[byte]] =
  if explicit.isSome():
    return Opt.some(explicit.get())

  let extRecord = disco.record().valueOr:
    error "failed to create extended peer record", error
    return Opt.none(seq[byte])
  Opt.some(extRecord.encode())

proc advertiseToRegistrar*(
  disco: ServiceDiscovery,
  serviceId: ServiceId,
  registrar: PeerId,
  ticket: Opt[Ticket],
  advert: seq[byte],
) {.async: (raises: [CancelledError]).}

proc startLocalRegistration(disco: ServiceDiscovery) =
  ## Starts (or restarts) the single long-lived local self-registration task.

  if not disco.localRegistrationLoop.isNil and not disco.localRegistrationLoop.finished:
    return
  if disco.services.len == 0:
    return

  let someService = disco.services.toSeq()[0]
  let sid = someService.id.hashServiceId()

  let advertBytes = (
    if sid in disco.advertiser.providedAdverts:
      disco.advertiser.providedAdverts.getOrDefault(sid)
    else:
      disco.getAdvertBytes(Opt.none(seq[byte])).get(@[])
  )
  if advertBytes.len == 0:
    return

  let selfPeer = disco.switch.peerInfo.peerId
  disco.localRegistrationLoop =
    disco.advertiseToRegistrar(sid, selfPeer, Opt.none(Ticket), advertBytes)

proc stopLocalRegistration(
    disco: ServiceDiscovery
) {.async: (raises: [CancelledError]).} =
  if disco.localRegistrationLoop.isNil:
    return

  await disco.localRegistrationLoop.cancelAndWait()

  disco.localRegistrationLoop = nil

proc maintainRegistrations*(
    disco: ServiceDiscovery
) {.async: (raises: [CancelledError]).} =
  ## Periodic enforcement of the remote registration invariant:
  ##
  ## We maintain (up to) kRegister live registrars per bucket from each
  ## service's routing table. On Confirmed we terminate the task so the
  ## maintenance loop can rotate the slot to another peer in the bucket.

  cleanupFinishedTasks(disco.advertiser)

  let selfPeer = disco.switch.peerInfo.peerId

  for svc in disco.services:
    let sid = svc.id.hashServiceId()
    let table = disco.rtManager.getTable(sid).valueOr:
      continue

    # --- Remote registrars (bucketIdx >= 0) ---
    var activePerBucket = initTable[int, HashSet[PeerId]]()
    for t in disco.advertiser.running:
      if t.serviceId == sid and not t.fut.finished and t.bucketIdx >= 0:
        activePerBucket.mgetOrPut(t.bucketIdx, initHashSet[PeerId]()).incl(t.registrar)

    for bucketIdx, bucket in table.buckets.pairs:
      if bucket.peers.len == 0:
        continue

      var active = activePerBucket.getOrDefault(bucketIdx)

      # Drop tasks for peers that are no longer in this bucket (stale after refresh)
      var stale: seq[AdvertiseTask]
      for t in disco.advertiser.running:
        if t.serviceId == sid and t.bucketIdx == bucketIdx and not t.fut.finished:
          let regKey = t.registrar.toKey()
          if not bucket.peers.anyIt(it.nodeId == regKey):
            stale.add(t)
      for t in stale:
        t.fut.cancelSoon()
        disco.advertiser.running.excl(t)
        cd_advertiser_pending_actions.dec()
        active.excl(t.registrar)

      let target = min(disco.discoConfig.kRegister, bucket.peers.len)
      let deficit = target - active.len
      if deficit <= 0:
        continue

      var candidates: seq[PeerId]
      for p in bucket.peers:
        let pid = p.nodeId.toPeerId().valueOr:
          continue
        if pid notin active and pid != selfPeer:
          candidates.add(pid)

      let advertBytes = (
        if sid in disco.advertiser.providedAdverts:
          disco.advertiser.providedAdverts.getOrDefault(sid)
        else:
          disco.getAdvertBytes(Opt.none(seq[byte])).get(@[])
      )
      if advertBytes.len == 0:
        continue

      let toAdd = disco.rng.pick(candidates, deficit).valueOr:
        continue

      for registrar in toAdd:
        let fut =
          disco.advertiseToRegistrar(sid, registrar, Opt.none(Ticket), advertBytes)
        let task = AdvertiseTask(
          fut: fut, serviceId: sid, registrar: registrar, bucketIdx: bucketIdx
        )
        disco.advertiser.running.incl(task)
        cd_advertiser_pending_actions.inc()

  # Defensive restart of the local registration loop if it died unexpectedly
  # while we still provide services.
  if disco.services.len > 0 and
      (disco.localRegistrationLoop.isNil or disco.localRegistrationLoop.finished):
    disco.startLocalRegistration()

proc maintainAdvertiser*(
    disco: ServiceDiscovery
) {.async: (raises: [CancelledError]).} =
  heartbeat "advertiser registration maintenance",
    disco.config.bucketRefreshTime, sleepFirst = true:
    await disco.maintainRegistrations()

proc localRegister(disco: ServiceDiscovery, msg: Message): Result[Message, string] =
  return ok(disco.registration(disco.switch.peerInfo.peerId, msg))

proc sendRegister*(
    disco: ServiceDiscovery,
    peerId: PeerId,
    serviceId: ServiceId,
    ad: seq[byte],
    ticket: Opt[Ticket] = Opt.none(Ticket),
): Future[Result[RegistrationResponse, string]] {.async: (raises: [CancelledError]).} =
  let msg = Message(
    msgType: Opt.some(MessageType.register),
    key: Opt.some(serviceId),
    register: Opt.some(
      RegisterMessage(
        advertisement: Opt.some(ad),
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

proc ticketRetryDelay*(ticket: Ticket, now: Moment): Duration {.raises: [].} =
  ## Time to sleep before presenting ``ticket`` so the registrar sees it inside
  ## the eligibility window ``[tMod + tWaitFor, tMod + tWaitFor + delta]``.
  let tMod = ticket.tMod.valueOr:
    return ZeroDuration
  
  let tWaitFor = ticket.tWaitFor.valueOr:
    return ZeroDuration
  
  let eligibility = tMod + tWaitFor
  
  if now >= eligibility:
    return ZeroDuration
  
  return eligibility - now

proc advertiseToRegistrar*(
    disco: ServiceDiscovery,
    serviceId: ServiceId,
    registrar: PeerId,
    ticket: Opt[Ticket],
    advert: seq[byte],
) {.async: (raises: [CancelledError]).} =
  doAssert not disco.clientMode, "not supported in client mode"

  if not disco.rtManager.hasService(serviceId):
    error "no service routing table found", serviceId
    return

  cd_advertiser_actions_executed.inc()

  let isSelf = registrar == disco.switch.peerInfo.peerId
  var currentTicket = ticket

  debug "registering advert", serviceId, registrar, isSelf

  while true:
    let response = (
      await disco.sendRegister(registrar, serviceId, advert, currentTicket)
    ).valueOr:
      error "failed to register ad", serviceId, registrar, error
      return

    disco.updatePeers(response.closerPeers)

    for p in response.closerPeers:
      disco.rtManager.insertPeer(serviceId, p.peerId.toKey())

    case response.status
    of kademlia_protobuf.RegistrationStatus.Confirmed:
      debug "advert accepted", serviceId, registrar

      await sleepAsync(disco.discoConfig.advertExpiry)

      if isSelf:
        # Local registration task (the single long-lived one stored in
        # localRegistrationLoop). Keep refreshing so our advert stays
        # current in the local registrar.
        continue
      else:
        # For remote registrars: terminate the task after one lifetime.
        # The maintenance loop will then rotate this slot to another peer
        # in the same bucket.
        return
    of kademlia_protobuf.RegistrationStatus.Wait:
      let newTicket = response.ticket.valueOr:
        error "no ticket to retry with", serviceId, registrar
        return

      currentTicket = Opt.some(newTicket)

      let waitSecs = ticketRetryDelay(newTicket, Moment.now())

      if waitSecs > ZeroDuration:
        debug "waiting for registrar", serviceId, registrar, wait = $waitSecs
        await sleepAsync(waitSecs)
    of kademlia_protobuf.RegistrationStatus.Rejected:
      debug "registrar rejection, aborting", serviceId, registrar
      return

proc addProvidedService*(
    disco: ServiceDiscovery,
    service: ServiceInfo,
    advert: Opt[seq[byte]] = Opt.none(seq[byte]),
) =
  doAssert not disco.clientMode, "not supported in client mode"

  if not service.isValid():
    error "rejecting service with oversized data",
      service = service.id, dataLen = service.data.get().len, max = MaxServiceDataSize
    return

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

  # When a caller supplied an explicit advert we store it so that future
  # rotations / replacements (maintenance) reuse exactly the same bytes.
  if advert.isSome():
    disco.advertiser.providedAdverts[serviceId] = advert.get()

  let advertBytes = disco.getAdvertBytes(advert).valueOr:
    return

  for bucketIdx, bucket in advTable.buckets.pairs:
    if bucket.peers.len == 0:
      continue

    let peers = disco.rng.pick(bucket.peers, disco.discoConfig.kRegister).valueOr:
      continue

    for peer in peers:
      let registrar = peer.nodeId.toPeerId().valueOr:
        error "cannot convert key to peer id", error
        continue

      let fut =
        disco.advertiseToRegistrar(serviceId, registrar, Opt.none(Ticket), advertBytes)
      let task = AdvertiseTask(
        fut: fut, serviceId: serviceId, registrar: registrar, bucketIdx: bucketIdx
      )
      disco.advertiser.running.incl(task)
      cd_advertiser_pending_actions.inc()

  # Ensure the single local registration loop is running.
  # We start it when we add the first provided service.
  if disco.services.len == 1: # we just added the first one
    disco.startLocalRegistration()

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

  disco.advertiser.providedAdverts.del(sid)

  disco.rtManager.removeService(sid, Provided)
  for s in disco.services:
    if s.id == serviceId:
      disco.services.excl(s)
      break

  # If this was the last provided service, stop the unique local registration.
  if disco.services.len == 0:
    await disco.stopLocalRegistration()

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

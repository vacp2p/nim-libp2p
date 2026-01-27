import std/[hashes, tables, sequtils, sets, heapqueue, times, options]
import chronos, chronicles, results
import ../../[peerid, switch, multihash, cid, multicodec, multiaddress]
import ../../protobuf/minprotobuf
import ../../crypto/crypto
import ../kademlia/[types, routingtable, protobuf]
import ./[types, protobuf]

logScope:
  topics = "kad-disco"

proc new*(T: typedesc[Advertiser]): T =
  T(
    advTable: initTable[ServiceId, AdvertiseTable](),
    ongoing: initTable[ServiceId, OrderedTable[int, seq[PeerId]]](),
  )

proc addProvidedService*(
    advertiser: Advertiser,
    serviceId: ServiceId,
    config: KadDHTConfig,
    discoConf: KademliaDiscoveryConfig,
) =
  ## Include this service in the set of services this node provides.

  if serviceId notin advertiser.advTable:
    advertiser.advTable[serviceId] = AdvertiseTable.new(
      serviceId,
      config = RoutingTableConfig.new(
        replication = config.replication, maxBuckets = discoConf.bucketsCount
      ),
    )

proc removeProvidedService*(advertiser: Advertiser, serviceId: ServiceId) =
  ## Exclude this service from the set of services this node provides.

  if serviceId in advertiser.advTable:
    advertiser.advTable.del(serviceId)

proc emptyTicket(): Ticket =
  ## Helper to create an empty ticket for error cases
  Ticket(
    ad: Advertisement(
      serviceId: @[],
      peerId: PeerId(data: @[]),
      addrs: @[],
      signature: @[],
      metadata: @[],
      timestamp: 0,
    ),
    t_init: 0,
    t_mod: 0,
    t_wait_for: 0,
    signature: @[],
  )

proc sendRegister*(
    kad: KadDHT,
    peerId: PeerId,
    ad: Advertisement,
    codec: string,
    ticket: Opt[Ticket] = Opt.none(Ticket),
): Future[(RegistrationStatus, Ticket, seq[PeerId])] {.
    async: (raises: [CancelledError, DialFailedError, LPStreamError])
.} =
  ## Send REGISTER request to a peer
  let addrs = kad.switch.peerStore[AddressBook][peerId]
  if addrs.len == 0:
    return (RegistrationStatus.Rejected, emptyTicket(), @[])

  let conn = await kad.switch.dial(peerId, addrs, codec)
  defer:
    await conn.close()

  var msg =
    Message(msgType: MessageType.register, key: ad.serviceId, ad: Opt.some(ad.encode()))

  if ticket.isSome():
    msg.ticket = Opt.some(ticket.get().encode())

  await conn.writeLp(msg.encode().buffer)

  let replyBuf = await conn.readLp(MaxMsgSize)
  let reply = Message.decode(replyBuf).valueOr:
    debug "Failed to decode register response", err = error
    return (RegistrationStatus.Rejected, emptyTicket(), @[])

  let status =
    if reply.status.isSome():
      let s = reply.status.get().int
      if s == RegistrationStatus.Confirmed.ord:
        RegistrationStatus.Confirmed
      elif s == RegistrationStatus.Wait.ord:
        RegistrationStatus.Wait
      else:
        RegistrationStatus.Rejected
    else:
      RegistrationStatus.Rejected

  var responseTicket = emptyTicket()
  if reply.ticket.isSome():
    responseTicket = Ticket.decode(reply.ticket.get()).valueOr:
      debug "Failed to decode ticket", err = error
      emptyTicket()

  var closerPeers: seq[PeerId] = @[]
  for peer in reply.closerPeers:
    let peerId = PeerId.init(peer.id).valueOr:
      debug "Failed to decode peer id", err = error
      continue
    closerPeers.add(peerId)

  return (status, responseTicket, closerPeers)

proc advertiseSingle(
    disco: KademliaDiscovery, registrar: PeerId, ad: Advertisement, bucketIdx: int
) {.async.} =
  ## Advertise to a single registrar following RFC ADVERTISE_SINGLE
  var ticket: Opt[Ticket] = Opt.none(Ticket)

  while true:
    let (status, newTicket, closerPeers) =
      await sendRegister(disco, registrar, ad, ExtendedKademliaDiscoveryCodec, ticket)

    # Add closerPeers to AdvT
    if ad.serviceId in disco.advertiser.advTable:
      for peerId in closerPeers:
        discard disco.advertiser.advTable[ad.serviceId].insert(peerId.toKey())

    if status == RegistrationStatus.Confirmed:
      # Wait for advert expiry then re-advertise
      await sleepAsync(int(disco.discoConf.advertExpiry * 1000))
      break
    elif status == RegistrationStatus.Wait:
      let waitTime = min(disco.discoConf.advertExpiry, newTicket.t_wait_for.float64)
      await sleepAsync(int(waitTime * 1000))
      ticket = Opt.some(newTicket)
      continue
    else: # Rejected
      break

  # Remove from ongoing tracking
  if ad.serviceId in disco.advertiser.ongoing:
    if bucketIdx in disco.advertiser.ongoing[ad.serviceId]:
      disco.advertiser.ongoing[ad.serviceId][bucketIdx].keepItIf(it != registrar)

proc advertiseService*(disco: KademliaDiscovery, serviceId: ServiceId) {.async.} =
  ## Advertise a service following RFC ADVERTISE algorithm
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
    return

  # Ensure service is in advTable
  disco.advertiser.addProvidedService(serviceId, disco.config, disco.discoConf)

  let rtable = disco.advertiser.advTable[serviceId]

  # Initialize ongoing tracking if needed
  if serviceId notin disco.advertiser.ongoing:
    disco.advertiser.ongoing[serviceId] = initOrderedTable[int, seq[PeerId]]()

  block outer:
    for bucketIdx in 0 ..< disco.discoConf.bucketsCount:
      var bucket = rtable.buckets[bucketIdx]
      if bucket.peers.len == 0:
        continue

      shuffle(disco.rng, bucket.peers)

      # Get ongoing count for this bucket
      let ongoingCount =
        if bucketIdx in disco.advertiser.ongoing[serviceId]:
          disco.advertiser.ongoing[serviceId][bucketIdx].len
        else:
          0

      let numToRegister = disco.discoConf.kRegister - ongoingCount

      if numToRegister <= 0:
        continue

      let numPeers = min(numToRegister, bucket.peers.len)
      for i in 0 ..< numPeers:
        let peerId = bucket.peers[i].nodeId.toPeerId().valueOr:
          error "Cannot convert key to peer id", error = error
          continue

        # Track as ongoing
        if bucketIdx notin disco.advertiser.ongoing[serviceId]:
          disco.advertiser.ongoing[serviceId][bucketIdx] = @[]
        disco.advertiser.ongoing[serviceId][bucketIdx].add(peerId)

        # Async advertise to this registrar
        asyncCheck disco.advertiseSingle(peerId, ad, bucketIdx)

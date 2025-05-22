import chronos
import chronicles
import sequtils
import ../../peerid
import ./consts
import ./xordistance
import ./routingtable
import ./lookupstate
import ./requests
import ../protocol
import ../../switch
import ./protobuf
import ../../utils/heartbeat

logScope:
  topics = "libp2p discovery kad-dht"

type KadDHT* = ref object of LPProtocol
  switch: Switch
  rng: ref HmacDrbgContext
  rtable*: RoutingTable

  maintenanceLoop: Future[void]
  healthMonitorLoop: Future[void]

proc sendFindNode(
    kad: KadDHT, peerId: PeerId, targetId: PeerId
): Future[Message] {.async.} =
  let conn = await kad.switch.dial(peerId, KadCodec)
  defer:
    await conn.close()

  let msg =
    Message(msgType: Opt.some(MessageType.findNode), key: Opt.some(targetId.getBytes()))

  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(1024)).get() # TODO: fix
  if reply.msgType.get() != MessageType.findNode: # TODO: fix
    raise newException(ValueError, "unexpected message type in reply")

  return reply

proc waitRepliesOrTimeouts(
    pendingFutures: Table[PeerId, Future[Message]]
): Future[(seq[Message], seq[PeerId])] {.async.} =
  await allFutures(toSeq(pendingFutures.values))

  var receivedReplies: seq[Message] = @[]
  var failedPeers: seq[PeerId] = @[]

  for (peerId, replyFut) in pendingFutures.pairs:
    if replyFut.failed:
      failedPeers.add(peerId)
    else:
      receivedReplies.add(await replyFut)

  return (receivedReplies, failedPeers)

proc findNode(kad: KadDHT, target: PeerId): Future[seq[PeerId]] {.async.} =
  #debug "findNode", target = target
  # TODO: check if already exist in rtable
  # TODO: should it return a single peer instead? read spec

  var initialPeers = kad.rtable.findClosest(target, k)
  var state = LookupState.init(target, initialPeers)

  while not state.done:
    let toQuery = state.selectAlphaPeers()

    var pendingFutures: Table[PeerId, Future[Message]] =
      initTable[PeerId, Future[Message]]()

    for peer in toQuery:
      if pendingFutures.hasKey(peer):
        continue

      state.markPending(peer)
      # TODO: should store request to sendFindNode, and send them concurrently limited by alpha
      pendingFutures[peer] = kad.sendFindNode(peer, target).wait(5.seconds)
      # TODO: should this timeout be specified by the dev? maybe should be a config option
      state.activeQueries.inc

    let (successfulReplies, timedOutPeers) = await waitRepliesOrTimeouts(pendingFutures)

    for msg in successfulReplies:
      state.updateShortlist(
        msg,
        proc(p: PeerInfo) =
          kad.rtable.insert(p.peerId)
          kad.switch.peerStore[AddressBook][p.peerId] = p.addrs
          # TODO: add TTL to peerstore, otherwise we can spam it with junk
        ,
      )

    for timedOut in timedOutPeers:
      state.markFailed(timedOut)

    state.done = state.checkConvergence()

  return state.selectClosestK()

proc bootstrap*(kad: KadDHT, bootstrapNodes: seq[PeerInfo]) {.async.} =
  # TODO: every 10 minutes configurable, run once on start
  for b in bootstrapNodes:
    try:
      await kad.switch.connect(b.peerId, b.addrs)
      try: # Use alpha parall
        let msg = await kad.sendFindNode(b.peerId, kad.rtable.selfId).wait(5.seconds)
        for peer in msg.closerPeers:
          let p = PeerId.init(peer.id).get() # TODO:
          kad.rtable.insert(p)
          kad.switch.peerStore[AddressBook][p] = peer.addrs

        # bootstrap node replied succesfully. Adding to routing table
        kad.rtable.insert(b.peerId)
      except CatchableError as e:
        error "bootstrap failed", peerId = b.peerId, exc = e.msg

      debug "connected to bootstrap peer", peerId = b.peerId
    except CatchableError as e:
      error "failed to connect to bootstrap peer", peerId = b.peerId, error = e.msg

  try:
    # Adding some random node to prepopulate the table
    discard await kad.findNode(PeerId.random(kad.rng).get())
    info "bootstrap lookup complete"
  except CatchableError as e:
    error "bootstrap lookup failed", error = e.msg

proc refreshBuckets(kad: KadDHT) {.async.} =
  for i in 0 ..< kad.rtable.buckets.len:
    if kad.rtable.buckets[i].isStale():
      let randomId = randomIdInBucketRange(kad.rtable.selfId, i, kad.rng)
      discard await kad.findNode(randomId)

proc maintainBuckets(kad: KadDHT) {.async.} =
  heartbeat "refresh buckets", 10.minutes:
    await kad.refreshBuckets()

proc healthMonitor(kad: KadDHT) {.async.} =
  heartbeat "health monitor", 1.minutes:
    for idx, bucket in kad.rtable.buckets.pairs:
      var live = 0
      for peer in bucket.peers:
        if Moment.now() - peer.lastSeen < 30.minutes:
          live.inc
      debug "health check", bucket = idx, live = live, peersInBucket = bucket.peers.len
    await sleepAsync(1.minutes)

proc new*(
    T: typedesc[KadDHT], switch: Switch, rng: ref HmacDrbgContext = newRng()
): T {.raises: [].} =
  var rtable = RoutingTable.init(switch.peerInfo.peerId)
  let kad = T(rng: rng, switch: switch, rtable: rtable)

  kad.codec = KadCodec
  kad.handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      while not conn.atEof:
        let
          buf = await conn.readLp(4096)
          msg = Message.decode(buf).tryGet()

        case msg.msgType.tryGet()
        of MessageType.findNode:
          let targetIdBytes = msg.key.tryGet() # TODO:
          let targetId = PeerId.init(targetIdBytes).tryGet() # TODO:
          let closerPeers = kad.rtable.findClosest(targetId, k)
          let responsePb = encodeFindNodeReply(closerPeers, switch)
          await conn.writeLp(responsePb.buffer)

          # Peer is useful. adding to rtable
          # TODO: confirm if identify is triggered for all connections
          kad.rtable.insert(conn.peerId)
        else:
          raise newException(LPError, "unhandled kad-dht message type")
        # TODO: implement other types
    except CancelledError as exc:
      return
    except CatchableError as exc:
      return
    finally:
      await conn.close()

  return kad

method start*(
    kad: KadDHT
): Future[void] {.async: (raises: [CancelledError], raw: true).} =
  let fut = newFuture[void]()
  fut.complete()
  if kad.started:
    warn "Starting kad-dht twice"
    return fut

  kad.maintenanceLoop = kad.maintainBuckets()
  kad.healthMonitorLoop = kad.healthMonitor()
  kad.started = true

  info "kad-dht started"

  fut

method stop*(kad: KadDHT): Future[void] {.async: (raises: [], raw: true).} =
  if not kad.started:
    return

  kad.started = false
  kad.maintenanceLoop.cancelSoon()
  kad.healthMonitorLoop.cancelSoon()
  kad.maintenanceLoop = nil
  kad.healthMonitorLoop = nil
  return

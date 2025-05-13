import chronos
import chronicles
import sequtils
import ../../peerid
import ./consts
import ./xordistance
import ./routingtable
import ./lookupstate
import ../protocol
import ../../switch
import ./protobuf
import ../../utils/heartbeat

logScope:
  topics = "libp2p discovery kad-dht"

type KadDHT* = ref object of LPProtocol
  switch: Switch
  rng: ref HmacDrbgContext
  rtable: RoutingTable

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
      pendingFutures[peer] = kad.sendFindNode(peer, target).wait(5.seconds)
        # TODO: should this timeout be specified by the dev? maybe should be a config option
      state.activeQueries.inc

    let (successfulReplies, timedOutPeers) = await waitRepliesOrTimeouts(pendingFutures)

    for msg in successfulReplies:
      state.updateShortlist(
        msg,
        proc(p: PeerId) =
          kad.rtable.insert(p),
      )

    for timedOut in timedOutPeers:
      state.markFailed(timedOut)

    state.done = state.checkConvergence()

  return state.selectClosestK()

proc bootstrap(kad: KadDHT, bootstrapNodes: seq[PeerInfo]) {.async.} =
  # TODO: every 10 minutes configurable, run once on start
  for b in bootstrapNodes:
    try:
      await kad.switch.connect(b.peerId, b.addrs)
      debug "connected to bootstrap peer", peerId = b.peerId
    except CatchableError as e:
      error "failed to connect to bootstrap peer", peerId = b.peerId, error = e.msg

  try:
    discard await kad.findNode(kad.switch.peerInfo.peerId)
    #discard await kad.findNode(SOME_RANDOM_PEER) # TODO:
    debug "bootstrap lookup complete"
  except CatchableError as e:
    error "bootstrap lookup failed", error = e.msg

proc refreshBuckets(kad: KadDHT) {.async.} =
  for i in 0 ..< kad.rtable.buckets.len:
    if kad.rtable.buckets[i].isStale():
      let randomId = randomIdInBucketRange(kad.rtable.selfId, i)
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

proc handler(conn: Connection, rtable: RoutingTable) {.async.} =
  discard

# Implementations may choose to re-use streams by sending one or more RPC request messages on a single outgoing stream before closing it. Implementations must handle additional RPC request messages on an incoming stream.

#let requestBytes = await stream.readFullMessage()
#let request = decodeFindNodeRequest(requestBytes)

# TODO: add other request typs

#if request.type == FIND_NODE:
#  let targetId = request.key.get() # unwrap Option[seq[byte]] safely
#  let closerPeers = routingTable.findClosest(targetId, k)
#  let response = encodeFindNodeReply(closerPeers)
#  await stream.write(response)
#  await conn.close()
#else:
#  await conn.close()
#  return

proc new*(
    T: typedesc[KadDHT], switch: Switch, rng: ref HmacDrbgContext = newRng()
): T {.raises: [].} =
  var rtable = RoutingTable.init(switch.peerInfo.peerId)
  let kad = T(rng: rng, switch: switch, rtable: rtable)

  kad.handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      await handler(conn, rtable)
    finally:
      conn.close()
  kad.codec = KadCodec
  return kad

proc start*(kad: KadDHT, bootstrapNodes: seq[PeerInfo]) {.async.} =
  if kad.started:
    return

  kad.started = true

  if bootstrapNodes.len > 0:
    await kad.bootstrap(bootstrapNodes)

  kad.maintenanceLoop = kad.maintainBuckets()
  kad.healthMonitorLoop = kad.healthMonitor()

method stop*(kad: KadDHT): Future[void] {.async: (raises: [], raw: true).} =
  if not kad.started:
    return

  kad.started = false
  kad.maintenanceLoop.cancelSoon()
  kad.healthMonitorLoop.cancelSoon()
  kad.maintenanceLoop = nil
  kad.healthMonitorLoop = nil
  return

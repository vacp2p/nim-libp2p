import chronos
import chronicles
import sequtils
import ../../peerid
import ./consts
import ./xordistance
import ./routingtable
import ./lookupstate
import ./requests
import ./keys
import ../protocol
import ../../switch
import ./protobuf
import ../../utils/heartbeat
import std/[options, tables]
import results

logScope:
  topics = "kad-dht"

type KadDHT* = ref object of LPProtocol
  switch*: Switch
  rng*: ref HmacDrbgContext
  rtable*: RoutingTable
  maintenanceLoop: Future[void]

const MaxMsgSize = 4096

proc sendFindNode(
    kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress], targetId: Key
): Future[Message] {.
    async: (raises: [CancelledError, DialFailedError, ValueError, LPStreamError])
.} =
  let conn =
    if addrs.len == 0:
      await kad.switch.dial(peerId, KadCodec)
    else:
      await kad.switch.dial(peerId, addrs, KadCodec)

  defer:
    await conn.close()

  let msg = Message(msgType: MessageType.findNode, key: some(targetId.getBytes()))

  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).tryGet()

  if reply.msgType != MessageType.findNode:
    raise newException(ValueError, "unexpected message type in reply: " & $reply)

  return reply

proc waitRepliesOrTimeouts*(
    pendingFutures: Table[PeerId, Future[Message]]
): Future[(seq[Message], seq[PeerId])] {.async: (raises: [CancelledError]).} =
  await allFutures(toSeq(pendingFutures.values))

  var receivedReplies: seq[Message] = @[]
  var failedPeers: seq[PeerId] = @[]

  for (peerId, replyFut) in pendingFutures.pairs:
    try:
      receivedReplies.add(await replyFut)
    except CatchableError:
      failedPeers.add(peerId)
      error "could not send find_node to peer", peerId, err = getCurrentExceptionMsg()

  return (receivedReplies, failedPeers)

proc findNode*(
    kad: KadDHT, targetId: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  #debug "findNode", target = target
  # TODO: should it return a single peer instead? read spec

  var initialPeers = kad.rtable.findClosestPeers(targetId, DefaultReplic)
  var state = LookupState.init(targetId, initialPeers)
  var addrTable: Table[PeerId, seq[MultiAddress]] =
    initTable[PeerId, seq[MultiAddress]]()

  while not state.done:
    let toQuery = state.selectAlphaPeers()
    var pendingFutures = initTable[PeerId, Future[Message]]()

    for peer in toQuery:
      if pendingFutures.hasKey(peer):
        continue

      state.markPending(peer)

      pendingFutures[peer] = kad
        .sendFindNode(peer, addrTable.getOrDefault(peer, @[]), targetId)
        .wait(5.seconds)

      state.activeQueries.inc

    let (successfulReplies, timedOutPeers) = await waitRepliesOrTimeouts(pendingFutures)

    for msg in successfulReplies:
      for peer in msg.closerPeers:
        addrTable[PeerId.init(peer.id).get()] = peer.addrs
      state.updateShortlist(
        msg,
        proc(p: PeerInfo) =
          discard kad.rtable.insert(p.peerId)
          kad.switch.peerStore[AddressBook][p.peerId] = p.addrs
          # TODO: add TTL to peerstore, otherwise we can spam it with junk
          # TODO: for discovery interface, invoke the found-peer handler
          # TODO: when peer-find limit is reached, interupt the hunt.
        ,
      )

    for timedOut in timedOutPeers:
      state.markFailed(timedOut)

    state.done = state.checkConvergence()

  return state.selectClosestK()

proc bootstrap*(
    kad: KadDHT, bootstrapNodes: seq[PeerInfo]
) {.async: (raises: [CancelledError]).} =
  for b in bootstrapNodes:
    try:
      await kad.switch.connect(b.peerId, b.addrs)
      debug "connected to bootstrap peer", peerId = b.peerId
    except CatchableError as e:
      error "failed to connect to bootstrap peer", peerId = b.peerId, error = e.msg

    try:
      let msg =
        await kad.sendFindNode(b.peerId, b.addrs, kad.rtable.selfId).wait(5.seconds)
      for peer in msg.closerPeers:
        let p = PeerId.init(peer.id).tryGet()
        discard kad.rtable.insert(p)
        kad.switch.peerStore[AddressBook][p] = peer.addrs

      # bootstrap node replied succesfully. Adding to routing table
      discard kad.rtable.insert(b.peerId)
    except CatchableError as e:
      error "bootstrap failed for peer", peerId = b.peerId, exc = e.msg

  try:
    # Adding some random node to prepopulate the table
    discard await kad.findNode(PeerId.random(kad.rng).tryGet().toKey())
    info "bootstrap lookup complete"
  except CatchableError as e:
    error "bootstrap lookup failed", error = e.msg

proc refreshBuckets(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  for i in 0 ..< kad.rtable.buckets.len:
    if kad.rtable.buckets[i].isStale():
      let randomKey = randomKeyInBucketRange(kad.rtable.selfId, i, kad.rng)
      discard await kad.findNode(randomKey)

proc maintainBuckets(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh buckets", 10.minutes:
    await kad.refreshBuckets()

proc new*(
    T: typedesc[KadDHT], switch: Switch, rng: ref HmacDrbgContext = newRng()
): T {.raises: [].} =
  var rtable = RoutingTable.init(switch.peerInfo.peerId.toKey())
  let kad = T(rng: rng, switch: switch, rtable: rtable)

  kad.codec = KadCodec
  kad.handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      while not conn.atEof:
        let
          buf = await conn.readLp(MaxMsgSize)
          msg = Message.decode(buf).tryGet()

        case msg.msgType
        of MessageType.findNode:
          let targetIdBytes = msg.key.get()
          let targetId = PeerId.init(targetIdBytes).tryGet()
          let closerPeers = kad.rtable.findClosest(targetId.toKey(), DefaultReplic)
          let responsePb = encodeFindNodeReply(closerPeers, switch)
          await conn.writeLp(responsePb.buffer)

          # Peer is useful. adding to rtable
          discard kad.rtable.insert(conn.peerId)
        else:
          raise newException(LPError, "unhandled kad-dht message type")
    except CancelledError as exc:
      raise exc
    except CatchableError:
      discard
      # TODO: figure out why this fails:
      # error "could not handle request",
      #   peerId = conn.PeerId, err = getCurrentExceptionMsg()
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
  kad.started = true

  info "kad-dht started"

  fut

method stop*(kad: KadDHT): Future[void] {.async: (raises: [], raw: true).} =
  let fut = newFuture[void]()
  fut.complete()
  if not kad.started:
    return fut

  kad.started = false
  kad.maintenanceLoop.cancelSoon()
  kad.maintenanceLoop = nil
  return fut

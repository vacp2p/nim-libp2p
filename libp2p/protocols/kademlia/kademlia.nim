import std/[times, tables, sequtils, sets]
import chronos
import chronicles
import results
import ./[consts, xordistance, routingtable, lookupstate, requests, keys, protobuf]
import ../protocol
import ../../[peerid, switch, multihash]
import ../../utils/heartbeat

logScope:
  topics = "kad-dht"

## Currently a string, because for some reason, that's what is chosen at the protobuf level
## TODO: convert between RFC3339 strings and use of integers (i.e. the _correct_ way)
type TimeStamp* = string

type EntryRecord* = object
  value*: seq[byte]
  time*: TimeStamp

proc init*(
    T: typedesc[EntryRecord], value: Key, time: Opt[TimeStamp]
): EntryRecord {.gcsafe, raises: [].} =
  EntryRecord(value: value, time: time.get(TimeStamp(ts: $times.now().utc)))

type LocalTable* = Table[Key, EntryRecord]

type EntryValidator* = ref object of RootObj
method isValid*(
    self: EntryValidator, key: Key, value: seq[byte]
): bool {.base, raises: [], gcsafe.} =
  doAssert(false, "EntryValidator base not implemented")

type EntrySelector* = ref object of RootObj
method select*(
    self: EntrySelector, key: Key, values: seq[seq[byte]]
): Result[int, string] {.base, raises: [], gcsafe.} =
  doAssert(false, "EntrySelection base not implemented")

type DefaultEntryValidator* = ref object of EntryValidator
method isValid*(
    self: DefaultEntryValidator, key: Key, value: seq[byte]
): bool {.raises: [], gcsafe.} =
  return true

type DefaultEntrySelector* = ref object of EntrySelector
method select*(
    self: DefaultEntrySelector, key: Key, values: seq[seq[byte]]
): Result[int, string] {.raises: [], gcsafe.} =
  return ok(0)

type KadDHT* = ref object of LPProtocol
  switch: Switch
  rng: ref HmacDrbgContext
  rtable*: RoutingTable
  maintenanceLoop: Future[void]
  dataTable*: LocalTable
  entryValidator: EntryValidator
  entrySelector: EntrySelector

proc insert*(
    self: var LocalTable, key: Key, value: sink seq[byte], time: TimeStamp
) {.raises: [].} =
  debug "Local table insertion", key, value
  self[key] = EntryRecord(value: value, time: time)

proc get*(self: LocalTable, key: Key): Opt[EntryRecord] {.raises: [].} =
  if not self.hasKey(key):
    return Opt.none(EntryRecord)
  try:
    return Opt.some(self[key])
  except KeyError:
    doAssert false, "checked with hasKey"

const MaxMsgSize = 4096
# Forward declaration
proc findNode*(
  kad: KadDHT, targetId: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).}

proc sendFindNode(
    kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress], targetId: Key
): Future[Message] {.
    async: (raises: [CancelledError, DialFailedError, ValueError, LPStreamError])
.} =
  let conn = await kad.switch.dial(peerId, addrs, KadCodec)
  defer:
    await conn.close()

  let msg = Message(msgType: MessageType.findNode, key: Opt.some(targetId))
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).tryGet()
  if reply.msgType != MessageType.findNode:
    raise newException(ValueError, "Unexpected message type in reply: " & $reply)

  return reply

proc waitRepliesOrTimeouts(
    pendingFutures: Table[PeerId, Future[Message]]
): Future[(seq[Message], seq[PeerId])] {.async: (raises: [CancelledError]).} =
  await allFutures(pendingFutures.values.toSeq())

  var receivedReplies: seq[Message] = @[]
  var failedPeers: seq[PeerId] = @[]

  for (peerId, replyFut) in pendingFutures.pairs:
    try:
      receivedReplies.add(await replyFut)
    except CatchableError:
      failedPeers.add(peerId)
      error "Could not send find_node to peer", peerId, err = getCurrentExceptionMsg()

  return (receivedReplies, failedPeers)

proc dispatchPutVal(
    kad: KadDHT, peer: PeerId, key: Key, value: seq[byte]
): Future[void] {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let conn = await kad.switch.dial(peer, KadCodec)
  defer:
    await conn.close()
  let msg = Message(
    msgType: MessageType.putValue,
    record: Opt.some(Record(key: Opt.some(key), value: Opt.some(value))),
  )
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).valueOr:
    # todo log this more meaningfully
    error "PutValue reply decode fail", error = error, conn = conn
    return
  if reply != msg:
    error "Unexpected change between msg and reply: ",
      msg = msg, reply = reply, conn = conn

proc ensureBestValue(kad: KadDHT, key: Key, value: seq[byte]): Result[void, string] =
  kad.dataTable.get(key).withValue(existing):
    let selectedIdx = kad.entrySelector.select(key, @[value, existing.value]).valueOr:
      return err(error)
    if selectedIdx != 0:
      return err("can't replace a newer value with an older value")
  return ok()

proc putValue*(
    kad: KadDHT, key: Key, value: seq[byte], timeout: Opt[int]
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if not kad.entryValidator.isValid(key, value):
    return err("invalid key/value pair")

  kad.ensureBestValue(key, value).isOkOr:
    return err(error)

  let peers = await kad.findNode(key)
  # We first prime the sends so the data is ready to go
  let rpcBatch = peers.mapIt(kad.dispatchPutVal(it, key, value))
  # then we do the `move`, as insert takes the data as `sink`
  kad.dataTable.insert(key, value, $times.now().utc)
  try:
    # now that the all the data is where it needs to be in memory, we can dispatch the
    # RPCs
    await rpcBatch.allFutures().wait(chronos.seconds(timeout.get(5)))

    # It's quite normal for the dispatch to timeout, as it would require all calls to get
    # their response. Downstream users may desire some sort of functionality in the 
    # future to get rpc telemetry, but in the meantime, we just move on...
  except AsyncTimeoutError:
    discard
  return ok()

# Helper function forward declaration
proc checkConvergence(state: LookupState, me: PeerId): bool {.raises: [], gcsafe.}

proc findNode*(
    kad: KadDHT, targetId: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  ## Iteratively search for the k closest peers to a target ID.

  var initialPeers = kad.rtable.findClosestPeers(targetId, DefaultReplic)
  var state = LookupState.init(targetId, initialPeers, kad.rtable.hasher)
  var addrTable: Table[PeerId, seq[MultiAddress]]
  for p in initialPeers:
    addrTable[p] = kad.switch.peerStore[AddressBook][p]

  while not state.done:
    let toQuery = state.selectAlphaPeers()
    debug "Queries", list = toQuery.mapIt(it.shortLog()), addrTab = addrTable
    var pendingFutures = initTable[PeerId, Future[Message]]()

    for peer in toQuery.filterIt(kad.switch.peerInfo.peerId != it):
      state.markPending(peer)
      let addrs = addrTable.getOrDefault(peer, @[])
      if addrs.len == 0:
        state.markFailed(peer)
        continue
      pendingFutures[peer] =
        kad.sendFindNode(peer, addrs, targetId).wait(chronos.seconds(5))

      state.activeQueries.inc

    let (successfulReplies, timedOutPeers) = await waitRepliesOrTimeouts(pendingFutures)

    for msg in successfulReplies:
      for peer in msg.closerPeers:
        let pid = PeerId.init(peer.id)
        if not pid.isOk:
          error "Invalid PeerId in successful reply", peerId = peer.id
          continue
        addrTable[pid.get()] = peer.addrs
      state.updateShortlist(
        msg,
        proc(p: PeerInfo) {.raises: [].} =
          discard kad.rtable.insert(p.peerId)
          # Nodes might return different addresses for a peer, so we append instead of replacing
          try:
            var existingAddresses =
              kad.switch.peerStore[AddressBook][p.peerId].toHashSet()
            for a in p.addrs:
              existingAddresses.incl(a)
            kad.switch.peerStore[AddressBook][p.peerId] = existingAddresses.toSeq()
          except KeyError as exc:
            debug "Could not update shortlist", err = exc.msg
          # TODO: add TTL to peerstore, otherwise we can spam it with junk
        ,
        kad.rtable.hasher,
      )

    for timedOut in timedOutPeers:
      state.markFailed(timedOut)

    # Check for covergence: no active queries, and no other peers to be selected
    state.done = checkConvergence(state, kad.switch.peerInfo.peerId)

  return state.selectClosestK()

proc findPeer*(
    kad: KadDHT, peer: PeerId
): Future[Result[PeerInfo, string]] {.async: (raises: [CancelledError]).} =
  ## Walks the key space until it finds candidate addresses for a peer Id

  if kad.switch.peerInfo.peerId == peer:
    # Looking for yourself.
    return ok(kad.switch.peerInfo)

  if kad.switch.isConnected(peer):
    # Return known info about already connected peer
    return ok(PeerInfo(peerId: peer, addrs: kad.switch.peerStore[AddressBook][peer]))

  let foundNodes = await kad.findNode(peer.toKey())
  if not foundNodes.contains(peer):
    return err("peer not found")

  return ok(PeerInfo(peerId: peer, addrs: kad.switch.peerStore[AddressBook][peer]))

proc ping*(
    kad: KadDHT, peerId: PeerId, addrs: seq[MultiAddress]
): Future[bool] {.
    async: (raises: [CancelledError, DialFailedError, ValueError, LPStreamError])
.} =
  let conn = await kad.switch.dial(peerId, addrs, KadCodec)
  defer:
    await conn.close()

  let request = Message(msgType: MessageType.ping)
  await conn.writeLp(request.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).tryGet()

  reply == request

proc checkConvergence(state: LookupState, me: PeerId): bool {.raises: [], gcsafe.} =
  let ready = state.activeQueries == 0
  let noNew = selectAlphaPeers(state).filterIt(me != it).len == 0
  return ready and noNew

proc bootstrap*(
    kad: KadDHT, bootstrapNodes: seq[PeerInfo]
) {.async: (raises: [CancelledError]).} =
  for b in bootstrapNodes:
    try:
      await kad.switch.connect(b.peerId, b.addrs)
      debug "Connected to bootstrap peer", peerId = b.peerId
    except DialFailedError as exc:
      # at some point will want to bubble up a Result[void, SomeErrorEnum]
      error "failed to dial to bootstrap peer", peerId = b.peerId, error = exc.msg
      continue

    let msg =
      try:
        await kad.sendFindNode(b.peerId, b.addrs, kad.rtable.selfId).wait(
          chronos.seconds(5)
        )
      except CatchableError as exc:
        debug "Send find node exception during bootstrap",
          target = b.peerId, addrs = b.addrs, err = exc.msg
        continue
    for peer in msg.closerPeers:
      let p = PeerId.init(peer.id).valueOr:
        debug "Invalid peer id received", error = error
        continue
      discard kad.rtable.insert(p)

      kad.switch.peerStore[AddressBook][p] = peer.addrs

    # bootstrap node replied succesfully. Adding to routing table
    discard kad.rtable.insert(b.peerId)

  let key = PeerId.random(kad.rng).valueOr:
    doAssert(false, "this should never happen")
    return
  discard await kad.findNode(key.toKey())
  info "Bootstrap lookup complete"

proc refreshBuckets(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  for i in 0 ..< kad.rtable.buckets.len:
    if kad.rtable.buckets[i].isStale():
      let randomKey = randomKeyInBucketRange(kad.rtable.selfId, i, kad.rng)
      discard await kad.findNode(randomKey)

proc maintainBuckets(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh buckets", chronos.minutes(10):
    await kad.refreshBuckets()

proc new*(
    T: typedesc[KadDHT],
    switch: Switch,
    validator: EntryValidator = DefaultEntryValidator(),
    entrySelector: EntrySelector = DefaultEntrySelector(),
    rng: ref HmacDrbgContext = newRng(),
): T {.raises: [].} =
  var rtable = RoutingTable.new(switch.peerInfo.peerId.toKey(), Opt.none(XorDHasher))
  let kad = T(
    rng: rng,
    switch: switch,
    rtable: rtable,
    entryValidator: validator,
    entrySelector: entrySelector,
  )

  kad.codec = KadCodec
  kad.handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    defer:
      await conn.close()
    while not conn.atEof:
      let buf =
        try:
          await conn.readLp(MaxMsgSize)
        except LPStreamError as exc:
          debug "Read error when handling kademlia RPC", conn = conn, err = exc.msg
          return
      let msg = Message.decode(buf).valueOr:
        debug "Failed to decode message", err = error
        return

      case msg.msgType
      of MessageType.findNode:
        let targetIdBytes = msg.key.valueOr:
          error "FindNode message without key data present", msg = msg, conn = conn
          return
        let targetId = PeerId.init(targetIdBytes).valueOr:
          error "FindNode message without valid key data", msg = msg, conn = conn
          return
        let closerPeers = kad.rtable
          .findClosest(targetId.toKey(), DefaultReplic)
          # exclude the node requester because telling a peer about itself does not reduce the distance,
          .filterIt(it != conn.peerId.toKey())

        let responsePb = encodeFindNodeReply(closerPeers, switch)
        try:
          await conn.writeLp(responsePb.buffer)
        except LPStreamError as exc:
          debug "Write error when writing kad find-node RPC reply",
            conn = conn, err = exc.msg
          return

        # Peer is useful. adding to rtable
        discard kad.rtable.insert(conn.peerId)
      of MessageType.putValue:
        let record = msg.record.valueOr:
          error "No record in message buffer", msg = msg, conn = conn
          return
        let (key, value) =
          if record.key.isSome() and record.value.isSome():
            (record.key.unsafeGet(), record.value.unsafeGet())
          else:
            error "No key or no value in rpc buffer", msg = msg, conn = conn
            return

        # Value sanitisation done. Start insertion process
        if not kad.entryValidator.isValid(key, value):
          debug "Record is not valid", key, value
          return

        kad.ensureBestValue(key, value).isOkOr:
          error "Dropping received value", err = error
          return

        kad.dataTable.insert(key, value, $times.now().utc)
        # consistent with following link, echo message without change
        # https://github.com/libp2p/js-libp2p/blob/cf9aab5c841ec08bc023b9f49083c95ad78a7a07/packages/kad-dht/src/rpc/handlers/put-value.ts#L22
        try:
          await conn.writeLp(buf)
        except LPStreamError as exc:
          debug "Failed to send find-node RPC reply", conn = conn, err = exc.msg
          return
      of MessageType.ping:
        try:
          await conn.writeLp(buf)
        except LPStreamError as exc:
          debug "Failed to send ping reply", conn = conn, err = exc.msg
          return
      else:
        error "Unhandled kad-dht message type", msg = msg
        return
  return kad

proc setSelector*(kad: KadDHT, selector: EntrySelector) =
  doAssert(selector != nil)
  kad.entrySelector = selector

proc setValidator*(kad: KadDHT, validator: EntryValidator) =
  doAssert(validator != nil)
  kad.entryValidator = validator

method start*(kad: KadDHT): Future[void] {.async: (raises: [CancelledError]).} =
  if kad.started:
    warn "Starting kad-dht twice"
    return

  kad.maintenanceLoop = kad.maintainBuckets()
  kad.started = true

  info "Kad DHT started"

method stop*(kad: KadDHT): Future[void] {.async: (raises: []).} =
  if not kad.started:
    return

  kad.started = false
  kad.maintenanceLoop.cancelSoon()
  kad.maintenanceLoop = nil

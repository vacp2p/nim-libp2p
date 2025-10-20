import std/[times, tables, sequtils, sets]
import chronos
import chronicles
import results
import ./[consts, xordistance, routingtable, lookupstate, keys, protobuf]
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

type
  ReceivedTable = TableRef[PeerId, Opt[EntryRecord]]
  CandidatePeers = ref HashSet[PeerId]
  LocalTable* = Table[Key, EntryRecord]

type EntryValidator* = ref object of RootObj
method isValid*(
    self: EntryValidator, key: Key, record: EntryRecord
): bool {.base, raises: [], gcsafe.} =
  doAssert(false, "EntryValidator base not implemented")

type EntrySelector* = ref object of RootObj
method select*(
    self: EntrySelector, key: Key, records: seq[EntryRecord]
): Result[int, string] {.base, raises: [], gcsafe.} =
  doAssert(false, "EntrySelection base not implemented")

type DefaultEntryValidator* = ref object of EntryValidator
method isValid*(
    self: DefaultEntryValidator, key: Key, record: EntryRecord
): bool {.raises: [], gcsafe.} =
  return true

type DefaultEntrySelector* = ref object of EntrySelector
method select*(
    self: DefaultEntrySelector, key: Key, records: seq[EntryRecord]
): Result[int, string] {.raises: [], gcsafe.} =
  if records.len == 0:
    return err("No records to choose from")

  # Map value -> (count, firstIndex)
  var counts: Table[seq[byte], (int, int)]
  for i, v in records.mapIt(it.value):
    try:
      let (cnt, idx) = counts[v]
      counts[v] = (cnt + 1, idx)
    except KeyError:
      counts[v] = (1, i)

  # Find the first value with the highest count
  var bestIdx = 0
  var maxCount = -1
  var minFirstIdx = high(int)
  for _, (cnt, idx) in counts.pairs:
    if cnt > maxCount or (cnt == maxCount and idx < minFirstIdx):
      maxCount = cnt
      bestIdx = idx
      minFirstIdx = idx

  return ok(bestIdx)

type KadDHTConfig* = ref object
  validator*: EntryValidator
  selector*: EntrySelector
  timeout*: chronos.Duration
  retries*: int
  replication*: int
  alpha*: int
  ttl*: chronos.Duration
  quorum*: int

proc new*(
    T: typedesc[KadDHTConfig],
    validator: EntryValidator = DefaultEntryValidator(),
    selector: EntrySelector = DefaultEntrySelector(),
    timeout: chronos.Duration = DefaultTimeout,
    retries: int = DefaultRetries,
    replication: int = DefaultReplication,
    alpha: int = DefaultAlpha,
    ttl: chronos.Duration = DefaultTTL,
    quorum: int = DefaultQuorum,
): T {.raises: [].} =
  KadDHTConfig(
    validator: validator,
    selector: selector,
    timeout: timeout,
    retries: retries,
    replication: replication,
    alpha: alpha,
    ttl: ttl,
    quorum: quorum,
  )

type KadDHT* = ref object of LPProtocol
  switch: Switch
  rng: ref HmacDrbgContext
  rtable*: RoutingTable
  maintenanceLoop: Future[void]
  dataTable*: LocalTable
  config*: KadDHTConfig

proc insert*(
    self: var LocalTable, key: Key, value: sink seq[byte], time: TimeStamp
) {.raises: [].} =
  debug "Local table insertion", key = key, value = value
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

proc isBestValue(kad: KadDHT, key: Key, record: EntryRecord): bool =
  ## Returns whether `value` is a better value than what we have locally
  ## Always returns `true` if we don't have the value locally

  kad.dataTable.get(key).withValue(existing):
    kad.config.selector.select(key, @[record, existing]).withValue(selectedIdx):
      return selectedIdx == 0

  true

proc checkConvergence(state: LookupState, me: PeerId): bool {.raises: [], gcsafe.} =
  let ready = state.activeQueries == 0
  let noNew = state.selectAlphaPeers().filterIt(me != it).len == 0
  return ready and noNew

proc findNode*(
    kad: KadDHT, targetId: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  ## Iteratively search for the k closest peers to a target ID.

  var initialPeers = kad.rtable.findClosestPeerIds(targetId, kad.config.replication)
  var state = LookupState.init(
    targetId, initialPeers, kad.config.alpha, kad.config.replication,
    kad.rtable.config.hasher,
  )
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
        kad.rtable.config.hasher,
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

proc dispatchPutVal(
    switch: Switch, peer: PeerId, key: Key, value: seq[byte]
) {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let conn = await switch.dial(peer, KadCodec)
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

proc putValue*(
    kad: KadDHT, key: Key, value: seq[byte]
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let record = EntryRecord(value: value, time: $times.now().utc)

  if not kad.config.validator.isValid(key, record):
    return err("invalid key/value pair")

  if not kad.isBestValue(key, record):
    return err("Value rejected, we have a better one")

  let peers = await kad.findNode(key)

  kad.dataTable.insert(key, value, $times.now().utc)

  for chunk in peers.toChunks(kad.config.alpha):
    let rpcBatch = chunk.mapIt(kad.switch.dispatchPutVal(it, key, value))
    try:
      await rpcBatch.allFutures().wait(kad.config.timeout)
    except AsyncTimeoutError:
      # Dispatch will timeout if any of the calls don't receive a response (which is normal)
      discard

  ok()

proc dispatchGetVal(
    switch: Switch,
    peer: PeerId,
    key: Key,
    received: ReceivedTable,
    candidates: CandidatePeers,
) {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let conn = await switch.dial(peer, KadCodec)
  defer:
    await conn.close()
  let msg = Message(msgType: MessageType.getValue, key: Opt.some(key))
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).valueOr:
    error "GetValue reply decode fail", error = error, conn = conn
    return

  received[peer] = Opt.none(EntryRecord)

  for peer in reply.closerPeers:
    let p = PeerId.init(peer.id).valueOr:
      debug "Invalid peer id received", error = error
      continue
    candidates[].incl(p)

  let record = reply.record.valueOr:
    debug "GetValue returned empty record", msg = msg, reply = reply, conn = conn
    return

  let value = record.value.valueOr:
    debug "GetValue returned record with no value",
      msg = msg, reply = reply, conn = conn
    return

  let time = record.timeReceived.valueOr:
    debug "GetValue returned record with no timeReceived",
      msg = msg, reply = reply, conn = conn
    return

  received[peer] = Opt.some(EntryRecord(value: value, time: time))

proc bestValidRecord(
    kad: KadDHT, key: Key, received: ReceivedTable
): Result[EntryRecord, string] =
  var validRecords: seq[EntryRecord]
  for r in received.values():
    let record = r.valueOr:
      continue
    if kad.config.validator.isValid(key, record):
      validRecords.add(record)

  if validRecords.len() < kad.config.quorum:
    return err("Not enough valid records to achieve quorum")

  let selectedIdx = kad.config.selector.select(key, validRecords).valueOr:
    return err("Could not select best value")

  ok(validRecords[selectedIdx])

proc getValue*(
    kad: KadDHT, key: Key
): Future[Result[EntryRecord, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let candidates = CandidatePeers()
  for p in (await kad.findNode(key)):
    candidates[].incl(p)
  let received = ReceivedTable()

  var curTry = 0
  while received.len < kad.config.quorum and candidates[].len > 0 and
      curTry < kad.config.retries:
    for chunk in candidates[].toSeq.toChunks(kad.config.alpha):
      let rpcBatch =
        candidates[].mapIt(kad.switch.dispatchGetVal(it, key, received, candidates))
      try:
        await rpcBatch.allFutures().wait(kad.config.timeout)
      except AsyncTimeoutError:
        # Dispatch will timeout if any of the calls don't receive a response (which is normal)
        discard
    # filter out peers that have responded
    candidates[] = candidates[].filterIt(not received.hasKey(it))
    curTry.inc()

  let best = ?kad.bestValidRecord(key, received)

  # insert value to our localtable
  kad.dataTable.insert(key, best.value, $times.now().utc)

  # update peers that
  # - don't have best value
  # - don't have valid records
  # - don't have the values at all
  var rpcBatch: seq[Future[void]]
  for p, r in received:
    let record = r.valueOr:
      # peer doesn't have value
      rpcBatch.add(kad.switch.dispatchPutVal(p, key, best.value))
      continue
    if record.value != best.value:
      # value is invalid or not best
      rpcBatch.add(kad.switch.dispatchPutVal(p, key, best.value))

  try:
    await rpcBatch.allFutures().wait(chronos.seconds(5))
  except AsyncTimeoutError:
    # Dispatch will timeout if any of the calls don't receive a response (which is normal)
    discard

  ok(best)

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

proc findClosestPeers*(kad: KadDHT, target: Key): seq[Peer] =
  var closestPeers: seq[Peer]
  let selfKey = kad.switch.peerInfo.peerId.toKey()
  for p in kad.rtable.findClosest(target, kad.config.replication):
    if p == selfKey: # do not return self as one of closest peers
      continue
    let peer = p.toPeer(kad.switch).valueOr:
      continue
    closestPeers.add(peer)
  return closestPeers

proc maintainBuckets(kad: KadDHT) {.async: (raises: [CancelledError]).} =
  heartbeat "refresh buckets", chronos.minutes(10):
    await kad.refreshBuckets()

proc handleFindNode(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let targetIdBytes = msg.key.valueOr:
    error "FindNode message without key data present", msg = msg, conn = conn
    return
  let targetId = PeerId.init(targetIdBytes).valueOr:
    error "FindNode message without valid key data", msg = msg, conn = conn
    return

  try:
    await conn.writeLp(
      Message(
        msgType: MessageType.findNode,
        closerPeers: kad.findClosestPeers(targetId.toKey()),
      ).encode().buffer
    )
  except LPStreamError as exc:
    debug "Write error when writing kad find-node RPC reply", conn = conn, err = exc.msg
    return

  # Peer is useful. adding to rtable
  discard kad.rtable.insert(conn.peerId)

proc handleGetValue(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let key = msg.key.valueOr:
    error "No key in rpc buffer", msg = msg, conn = conn
    return

  let entryRecord = kad.dataTable.get(key).valueOr:
    try:
      await conn.writeLp(
        Message(
          msgType: MessageType.getValue,
          key: Opt.some(key),
          closerPeers: kad.findClosestPeers(key),
        ).encode().buffer
      )
    except LPStreamError as exc:
      debug "Failed to send get-value RPC reply", conn = conn, err = exc.msg
    return

  try:
    await conn.writeLp(
      Message(
        msgType: MessageType.getValue,
        key: Opt.some(key),
        record: Opt.some(
          Record(
            key: Opt.some(key),
            value: Opt.some(entryRecord.value),
            timeReceived: Opt.some(entryRecord.time),
          )
        ),
        closerPeers: kad.findClosestPeers(key),
      ).encode().buffer
    )
  except LPStreamError as exc:
    debug "Failed to send get-value RPC reply", conn = conn, err = exc.msg
    return

proc handlePutValue(
    kad: KadDHT, conn: Connection, msg: Message
) {.async: (raises: [CancelledError]).} =
  let record = msg.record.valueOr:
    error "No record in message buffer", msg = msg, conn = conn
    return

  let (key, entryRecord) =
    try:
      (record.key.get(), EntryRecord(value: record.value.get(), time: $times.now().utc))
    except KeyError:
      error "No key, value or timeReceived in buffer", msg = msg, conn = conn
      return

  # Value sanitisation done. Start insertion process
  if not kad.config.validator.isValid(key, entryRecord):
    debug "Record is not valid", key, entryRecord
    return

  if not kad.isBestValue(key, entryRecord):
    error "Dropping received value, we have a better one"
    return

  kad.dataTable.insert(key, entryRecord.value, $times.now().utc)
  # consistent with following link, echo message without change
  # https://github.com/libp2p/js-libp2p/blob/cf9aab5c841ec08bc023b9f49083c95ad78a7a07/packages/kad-dht/src/rpc/handlers/put-value.ts#L22
  try:
    await conn.writeLp(msg.encode().buffer)
  except LPStreamError as exc:
    debug "Failed to send find-node RPC reply", conn = conn, err = exc.msg
    return

proc new*(
    T: typedesc[KadDHT],
    switch: Switch,
    config: KadDHTConfig = KadDHTConfig.new(),
    rng: ref HmacDrbgContext = newRng(),
): T {.raises: [].} =
  var rtable = RoutingTable.new(
    switch.peerInfo.peerId.toKey(),
    config = RoutingTableConfig.new(replication = config.replication),
  )
  let kad = T(rng: rng, switch: switch, rtable: rtable, config: config)

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
        except LPStreamEOFError:
          return
        except LPStreamError as exc:
          debug "Read error when handling kademlia RPC", conn = conn, err = exc.msg
          return
      let msg = Message.decode(buf).valueOr:
        debug "Failed to decode message", err = error
        return

      case msg.msgType
      of MessageType.findNode:
        await kad.handleFindNode(conn, msg)
      of MessageType.putValue:
        await kad.handlePutValue(conn, msg)
      of MessageType.getValue:
        await kad.handleGetValue(conn, msg)
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

import chronos
import chronicles
import sequtils
import sets
import ../../peerid
import ./consts
import ./xordistance
import ./routingtable
import ./lookupstate
import ./requests
import ./keys
import ../protocol
import ./protobuf
import ../../switch
import ../../multihash
import ../../utils/heartbeat
import std/[times, options, tables]
import results

logScope:
  topics = "kad-dht"

type EntryKey* = object
  data: seq[byte]

proc init*(T: typedesc[EntryKey], inner: seq[byte]): EntryKey {.gcsafe, raises: [].} =
  EntryKey(data: inner)

type EntryValue* = object
  data*: seq[byte] # public because needed for tests

proc init*(
    T: typedesc[EntryValue], inner: seq[byte]
): EntryValue {.gcsafe, raises: [].} =
  EntryValue(data: inner)

type TimeStamp* = object
  # Currently a string, because for some reason, that's what is chosen at the protobuf level
  # TODO: convert between RFC3339 strings and use of integers (i.e. the _correct_ way)
  ts*: string # only public because needed for tests

type EntryRecord* = object
  value*: EntryValue # only public because needed for tests
  time*: TimeStamp # only public because needed for tests

proc init*(
    T: typedesc[EntryRecord], value: EntryValue, time: Option[TimeStamp]
): EntryRecord {.gcsafe, raises: [].} =
  EntryRecord(value: value, time: time.get(TimeStamp(ts: $times.now().utc)))

type LocalTable* = object
  entries*: Table[EntryKey, EntryRecord] # public because needed for tests

proc init(self: typedesc[LocalTable]): LocalTable {.raises: [].} =
  LocalTable()

type EntryCandidate* = object
  key*: EntryKey
  value*: EntryValue

type ValidatedEntry* = object
  key: EntryKey
  value: EntryValue

proc init*(
    T: typedesc[ValidatedEntry], key: EntryKey, value: EntryValue
): ValidatedEntry {.gcsafe, raises: [].} =
  ValidatedEntry(key: key, value: value)

type EntryValidator* = ref object of RootObj
method isValid*(
    self: EntryValidator, key: EntryKey, val: EntryValue
): bool {.base, raises: [], gcsafe.} =
  doAssert(false, "unimplimented base method")

type EntrySelector* = ref object of RootObj
method select*(
    self: EntrySelector, cand: EntryRecord, others: seq[EntryRecord]
): Result[EntryRecord, string] {.base, raises: [], gcsafe.} =
  doAssert(false, "EntrySelection base not implemented")

type KadDHT* = ref object of LPProtocol
  switch: Switch
  rng: ref HmacDrbgContext
  rtable*: RoutingTable
  maintenanceLoop: Future[void]
  dataTable*: LocalTable
  entryValidator: EntryValidator
  entrySelector: EntrySelector

proc insert*(
    self: var LocalTable, value: sink ValidatedEntry, time: TimeStamp
) {.raises: [].} =
  debug "local table insertion", key = value.key.data, value = value.value.data
  self.entries[value.key] = EntryRecord(value: value.value, time: time)

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

proc waitRepliesOrTimeouts(
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

proc dispatchPutVal(
    kad: KadDHT, peer: PeerId, entry: ValidatedEntry
): Future[void] {.async: (raises: [CancelledError, DialFailedError, LPStreamError]).} =
  let conn = await kad.switch.dial(peer, KadCodec)
  defer:
    await conn.close()
  let msg = Message(
    msgType: MessageType.putValue,
    record: some(Record(key: some(entry.key.data), value: some(entry.value.data))),
  )
  await conn.writeLp(msg.encode().buffer)

  let reply = Message.decode(await conn.readLp(MaxMsgSize)).valueOr:
    # todo log this more meaningfully
    error "putValue reply decode fail", error = error, conn = conn
    return
  if reply != msg:
    error "unexpected change between msg and reply: ",
      msg = msg, reply = reply, conn = conn

proc putValue*(
    kad: KadDHT, entKey: EntryKey, value: EntryValue, timeout: Option[int]
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if not kad.entryValidator.isValid(entKey, value):
    return err("invalid key/value pair")

  try:
    let others: seq[EntryRecord] =
      if entKey in kad.dataTable.entries:
        @[kad.dataTable.entries[entKey]]
      else:
        @[]

    let candAsRec = EntryRecord.init(value, none(TimeStamp))
    let confirmedRec = kad.entrySelector.select(candAsRec, others).valueOr:
      error "application provided selector error (local)", msg = error
      return err(error)
    trace "local putval",
      candidate = candAsRec, others = others, selected = confirmedRec

    let validEnt = ValidatedEntry.init(entKey, confirmedRec.value)

    let peers = await kad.findNode(entKey.data.toKey())
    # We first prime the sends so the data is ready to go
    let rpcBatch = peers.mapIt(kad.dispatchPutVal(it, validEnt))
    # then we do the `move`, as insert takes the data as `sink`
    kad.dataTable.insert(validEnt, confirmedRec.time)
    try:
      # now that the all the data is where it needs to be in memory, we can dispatch the
      # RPCs
      await rpcBatch.allFutures().wait(chronos.seconds(timeout.get(5)))

    # It's quite normal for the dispatch to timeout, as it would require all calls to get
    # their response. Downstream users may desire some sort of functionality in the 
    # future to get rpc telemetry, but in the meantime, we just move on...
    except AsyncTimeoutError:
      discard

    return results.ok()
  except CatchableError as e:
    return err("todo: refine exceptions - " & e.msg)

# Helper function forward declaration
proc checkConvergence(state: LookupState, me: PeerId): bool {.raises: [], gcsafe.}

proc findNode*(
    kad: KadDHT, targetId: Key
): Future[seq[PeerId]] {.async: (raises: [CancelledError]).} =
  ## Node lookup. Iteratively search for the k closest peers to a target ID.
  ## Not necessarily will return the target itself

  #debug "findNode", target = target

  var initialPeers = kad.rtable.findClosestPeers(targetId, DefaultReplic)
  var state = LookupState.init(targetId, initialPeers, kad.rtable.hasher)
  var addrTable: Table[PeerId, seq[MultiAddress]] =
    initTable[PeerId, seq[MultiAddress]]()

  while not state.done:
    let toQuery = state.selectAlphaPeers()
    debug "queries", list = toQuery.mapIt(it.shortLog()), addrTab = addrTable
    var pendingFutures = initTable[PeerId, Future[Message]]()

    # TODO: pending futures always empty here, no?
    for peer in toQuery.filterIt(
      kad.switch.peerInfo.peerId != it or pendingFutures.hasKey(it)
    ):
      state.markPending(peer)

      pendingFutures[peer] = kad
        .sendFindNode(peer, addrTable.getOrDefault(peer, @[]), targetId)
        .wait(chronos.seconds(5))

      state.activeQueries.inc

    let (successfulReplies, timedOutPeers) = await waitRepliesOrTimeouts(pendingFutures)

    for msg in successfulReplies:
      for peer in msg.closerPeers:
        let pid = PeerId.init(peer.id)
        if not pid.isOk:
          error "PeerId init went bad. this is unusual", data = peer.id
          continue
        addrTable[pid.get()] = peer.addrs
      state.updateShortlist(
        msg,
        proc(p: PeerInfo) =
          discard kad.rtable.insert(p.peerId)
          # Nodes might return different addresses for a peer, so we append instead of replacing
          var existingAddresses =
            kad.switch.peerStore[AddressBook][p.peerId].toHashSet()
          for a in p.addrs:
            existingAddresses.incl(a)
          kad.switch.peerStore[AddressBook][p.peerId] = existingAddresses.toSeq()
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
      debug "connected to bootstrap peer", peerId = b.peerId
    except CatchableError as e:
      error "failed to connect to bootstrap peer", peerId = b.peerId, error = e.msg

    try:
      let msg = await kad.sendFindNode(b.peerId, b.addrs, kad.rtable.selfId).wait(
        chronos.seconds(5)
      )
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
  heartbeat "refresh buckets", chronos.minutes(10):
    await kad.refreshBuckets()

proc new*(
    T: typedesc[KadDHT],
    switch: Switch,
    validator: EntryValidator,
    entrySelector: EntrySelector,
    rng: ref HmacDrbgContext = newRng(),
): T {.raises: [].} =
  var rtable = RoutingTable.init(switch.peerInfo.peerId.toKey(), Opt.none(XorDHasher))
  let kad = T(
    rng: rng,
    switch: switch,
    rtable: rtable,
    dataTable: LocalTable.init(),
    entryValidator: validator,
    entrySelector: entrySelector,
  )

  kad.codec = KadCodec
  kad.handler = proc(
      conn: Connection, proto: string
  ) {.async: (raises: [CancelledError]).} =
    try:
      defer:
        await conn.close()
      while not conn.atEof:
        let
          buf = await conn.readLp(MaxMsgSize)
          msg = Message.decode(buf).tryGet()

        case msg.msgType
        of MessageType.findNode:
          let targetIdBytes = msg.key.valueOr:
            error "findNode message without key data present", msg = msg, conn = conn
            return
          let targetId = PeerId.init(targetIdBytes).valueOr:
            error "findNode message without valid key data", msg = msg, conn = conn
            return
          let closerPeers = kad.rtable
            .findClosest(targetId.toKey(), DefaultReplic)
            # exclude the node requester because telling a peer about itself does not reduce the distance,
            .filterIt(it != conn.peerId.toKey())

          let responsePb = encodeFindNodeReply(closerPeers, switch)
          await conn.writeLp(responsePb.buffer)

          # Peer is useful. adding to rtable
          discard kad.rtable.insert(conn.peerId)
        of MessageType.putValue:
          let record = msg.record.valueOr:
            error "no record in message buffer", msg = msg, conn = conn
            return
          let (skey, svalue) =
            if record.key.isSome() and record.value.isSome():
              (record.key.unsafeGet(), record.value.unsafeGet())
            else:
              error "no key or no value in rpc buffer", msg = msg, conn = conn
              return
          let key = EntryKey.init(skey)
          let value = EntryValue.init(svalue)

          # Value sanatisation done. Start insertion process
          if not kad.entryValidator.isValid(key, value):
            return

          let others =
            if kad.dataTable.entries.contains(key):
              @[kad.dataTable.entries[key]]
            else:
              @[]
          let candRec = EntryRecord.init(value, none(TimeStamp))
          let selectedRec = kad.entrySelector.select(candRec, others).valueOr:
            error "application provided selector error", msg = error, conn = conn
            return
          trace "putval handler selection",
            cand = candRec, others = others, selected = selectedRec

          # Assume that if selection goes with another value, that it is valid
          let validated = ValidatedEntry(key: key, value: selectedRec.value)

          kad.dataTable.insert(validated, selectedRec.time)
          # consistent with following link, echo message without change
          # https://github.com/libp2p/js-libp2p/blob/cf9aab5c841ec08bc023b9f49083c95ad78a7a07/packages/kad-dht/src/rpc/handlers/put-value.ts#L22
          await conn.writeLp(buf)
        else:
          raise newException(LPError, "unhandled kad-dht message type")
    except CancelledError as exc:
      raise exc
    except CatchableError:
      discard
      # TODO: figure out why this fails:
      # error "could not handle request",
      #   peerId = conn.PeerId, err = getCurrentExceptionMsg()
  return kad

proc setSelector*(kad: KadDHT, selector: EntrySelector) =
  doAssert(selector != nil)
  kad.entrySelector = selector

proc setValidator*(kad: KadDHT, validator: EntryValidator) =
  doAssert(validator != nil)
  kad.entryValidator = validator

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

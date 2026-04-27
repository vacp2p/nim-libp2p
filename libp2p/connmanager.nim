# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[algorithm, tables, sets, sequtils]
import pkg/[chronos, chronicles, metrics]
import peerinfo, peerstore, stream/connection, muxers/muxer, errors, muxer_store

logScope:
  topics = "libp2p connmanager"

declareGauge(libp2p_peers, "total connected peers")
declareCounter(libp2p_connmgr_trim_total, "total connection manager trim cycles")
declareCounter(
  libp2p_connmgr_pruned_peers_total, "total peers pruned by connection manager"
)

const
  DefaultMaxConnections = 50
  DefaultMaxConnectionsPerPeer = 1
  ConnectionsUnlimited = high(int)

type
  DecayFn* = proc(value: int, elapsed: Duration): int {.gcsafe, raises: [].}
    ## Decay function applied to an ephemeral tag on each tick interval.
    ## Returns the new value; returning ≤0 removes the tag.

  DecayingTagValue = object
    value: int
    lastTick: Moment
    interval: Duration
    decayFn: DecayFn

  ScoringConfig* = object ## Configuration for connection scoring parameters.
    outboundBonus*: int = 100
      ## `outboundBonus` is added to the score of every peer with an outbound connection
    decayResolution*: Duration = 1.minutes
      ## `decayResolution` controls how often ephemeral tag decay functions are applied

  WatermarkConfig* = object
    ## Configuration for hi/lo watermark connection management.
    ## When peer count exceeds `highWater`, a trim cycle runs until
    ## peer count drops to `lowWater`.
    lowWater*: int ## target peer count after trimming
    highWater*: int ## peer count that triggers a trim cycle
    gracePeriod*: Duration ## newly connected peers are exempt from trimming
    silencePeriod*: Duration ## minimum interval between trim cycles

  TooManyConnectionsError* = object of LPError
  AlreadyExpectingConnectionError* = object of LPError

  ConnEventKind* {.pure.} = enum
    Connected
      ## A connection was made and securely upgraded - there may be
      ## more than one concurrent connection thus more than one upgrade
      ## event per peer.
    Disconnected
      ## Peer disconnected - this event is fired once per upgrade
      ## when the associated connection is terminated.

  ConnEvent* = object
    case kind*: ConnEventKind
    of ConnEventKind.Connected:
      incoming*: bool
    else:
      discard

  ConnEventHandler* = proc(peerId: PeerId, event: ConnEvent): Future[void] {.
    gcsafe, async: (raises: [CancelledError])
  .}

  PeerEventKind* {.pure.} = enum
    Left
    Joined
    Identified

  PeerEvent* = object
    case kind*: PeerEventKind
    of PeerEventKind.Joined, PeerEventKind.Identified:
      initiator*: bool
    else:
      discard

  PeerEventHandler* = proc(peerId: PeerId, event: PeerEvent): Future[void] {.
    gcsafe, async: (raises: [CancelledError])
  .}

  ConnManager* = ref object of RootObj
    closed: bool
    muxerStore: MuxerStore
    maxConnsPerPeer: int
    maxConnectionsIn: int
    maxConnectionsOut: int
    inSema: AsyncSemaphore
    outSema: AsyncSemaphore
    connEvents: array[ConnEventKind, OrderedSet[ConnEventHandler]]
    peerEvents: array[PeerEventKind, OrderedSet[PeerEventHandler]]
    readyEvents: Table[PeerId, Future[void].Raising([CancelledError])]
    readyPeers: HashSet[PeerId]
    expectedConnectionsOverLimit*: Table[(PeerId, Direction), Future[Muxer]]
    peerStore*: PeerStore
    watermark: Opt[WatermarkConfig]
    connectedAt: Table[PeerId, Moment]
    protectedPeers: Table[PeerId, HashSet[string]]
    trimFut: Future[void]
    lastTrim: Moment
    scoringConfig: ScoringConfig
    staticTags: Table[PeerId, Table[string, int]]
    decayingTags: Table[PeerId, Table[string, DecayingTagValue]]
    decayLoopFut: Future[void]

  ConnectionSlot* = object
    connManager: ConnManager
    direction: Direction

proc decayLinear*(coef: float): DecayFn =
  ## Returns a DecayFn that multiplies the tag value by `coef` on each tick.
  ## The tag is removed when the value drops to 0 or below.
  ## Example: decayLinear(0.9) reduces by 10% per interval.
  return proc(value: int, elapsed: Duration): int {.gcsafe, raises: [].} =
    int(float(value) * coef)

proc decayFixed*(amount: int): DecayFn =
  ## Returns a DecayFn that subtracts `amount` from the tag value on each tick.
  ## The tag is removed when the value drops to 0 or below.
  return proc(value: int, elapsed: Duration): int {.gcsafe, raises: [].} =
    value - amount

proc decayNone*(): DecayFn =
  ## Returns a DecayFn that never decays the value (permanent ephemeral tag).
  return proc(value: int, elapsed: Duration): int {.gcsafe, raises: [].} =
    value

proc newTooManyConnectionsError(): ref TooManyConnectionsError {.inline.} =
  result = newException(TooManyConnectionsError, "Too many connections")

proc new*(
    T: type ConnManager,
    maxConnections: int = -1,
    maxIn: int = -1,
    maxOut: int = -1,
    maxConnsPerPeer: int = -1,
    watermark: Opt[WatermarkConfig] = Opt.none(WatermarkConfig),
    scoringConfig: ScoringConfig = ScoringConfig(),
): ConnManager =
  ## Creates a `ConnManager`.
  ##
  ## Parameters `maxConnections`, `maxIn`, `maxOut`, and `maxConnsPerPeer`
  ## accept `-1` to mean "use the default value".
  ## 
  ## By default (no arguments), total connections are capped at `DefaultMaxConnections`.
  ## Pass `maxConnections` for a custom total cap, or `maxIn`/`maxOut` for
  ## independent per-direction caps.
  ##
  ## When `watermark` is provided without explicit connection limits the
  ## semaphore is omitted and hi/lo trimming is the only guard.  When both
  ## are provided the semaphore blocks new connections hard while trimming
  ## also prunes existing ones.
  let hasWatermark = watermark.isSome
  let hasInOut = maxIn > 0 and maxOut > 0
  let hasTotal = maxConnections > 0

  var inSema, outSema: AsyncSemaphore
  var maxInArg, maxOutArg: int

  if hasInOut:
    inSema = newAsyncSemaphore(maxIn)
    outSema = newAsyncSemaphore(maxOut)
    maxInArg = maxIn
    maxOutArg = maxOut
  elif hasTotal or not hasWatermark:
    let cap = if hasTotal: maxConnections else: DefaultMaxConnections
    let sema = newAsyncSemaphore(cap)
    inSema = sema
    outSema = sema
    maxInArg = cap
    maxOutArg = cap
  else:
    maxInArg = ConnectionsUnlimited
    maxOutArg = ConnectionsUnlimited

  T(
    muxerStore: MuxerStore.new(),
    maxConnsPerPeer:
      if maxConnsPerPeer >= 0: maxConnsPerPeer else: DefaultMaxConnectionsPerPeer,
      # issue#2328 must never be 0
    maxConnectionsIn: maxInArg,
    maxConnectionsOut: maxOutArg,
    inSema: inSema,
    outSema: outSema,
    watermark: watermark,
    scoringConfig: scoringConfig,
  )

proc connCount*(c: ConnManager, peerId: PeerId): int {.inline.} =
  c.muxerStore.count(peerId)

proc getReadyEvent(
    c: ConnManager, peerId: PeerId
): Future[void].Raising([CancelledError]) =
  c.readyEvents.withValue(peerId, readyEvent):
    if not readyEvent[].finished:
      return readyEvent[]

  let readyEvent = Future[void].Raising([CancelledError]).init()
  c.readyEvents[peerId] = readyEvent
  readyEvent

proc notifyPeerReady(c: ConnManager, peerId: PeerId) =
  c.readyPeers.incl(peerId)
  c.readyEvents.withValue(peerId, readyEvent):
    if not readyEvent[].finished:
      readyEvent[].complete()
    c.readyEvents.del(peerId)

proc clearPeerReadyState(c: ConnManager, peerId: PeerId) =
  c.readyPeers.excl(peerId)
  c.readyEvents.withValue(peerId, readyEvent):
    readyEvent[].cancelSoon()
    c.readyEvents.del(peerId)

proc waitForPeerReady*(
    c: ConnManager, peerId: PeerId, timeout = 5.seconds
): Future[bool] {.async: (raises: [CancelledError]).} =
  ## Wait until `storeMuxer` has emitted the `Connected` conn event for `peerId`.
  ## Existing ready peers bypass waiting.
  if c.closed:
    return false

  if peerId in c.readyPeers:
    return true

  let readyEvent = c.getReadyEvent(peerId)

  let readyJoin = readyEvent.join()
  if timeout <= 0.seconds:
    await readyJoin
  elif not (await readyJoin.withTimeout(timeout)):
    return false

  return readyEvent.finished and not readyEvent.cancelled()

proc maxConnections*(c: ConnManager, dir: Direction): int =
  if dir == Direction.In: c.maxConnectionsIn else: c.maxConnectionsOut

proc connectedPeers*(c: ConnManager, dir: Direction): seq[PeerId] =
  c.muxerStore.getPeers(dir)

proc getConnections*(c: ConnManager): Table[PeerId, seq[Muxer]] =
  return c.muxerStore.getAll()

proc addConnEventHandler*(
    c: ConnManager, handler: ConnEventHandler, kind: ConnEventKind
) =
  ## Add peer event handler - handlers must not raise exceptions!
  if handler.isNil:
    return
  c.connEvents[kind].incl(handler)

proc removeConnEventHandler*(
    c: ConnManager, handler: ConnEventHandler, kind: ConnEventKind
) =
  c.connEvents[kind].excl(handler)

proc triggerConnEvent*(
    c: ConnManager, peerId: PeerId, event: ConnEvent
) {.async: (raises: [CancelledError]).} =
  try:
    trace "About to trigger connection events", peer = peerId
    if c.connEvents[event.kind].len > 0:
      trace "triggering connection events", peer = peerId, event = $event.kind
      var connEvents = newSeqOfCap[Future[void]](c.connEvents[event.kind].len)
      for h in c.connEvents[event.kind]:
        connEvents.add(h(peerId, event))

      checkFutures(await allFinished(connEvents))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    warn "Exception in triggerConnEvent",
      description = exc.msg, peer = peerId, event = $event

proc addPeerEventHandler*(
    c: ConnManager, handler: PeerEventHandler, kind: PeerEventKind
) =
  ## Add peer event handler - handlers must not raise exceptions!
  if handler.isNil:
    return
  c.peerEvents[kind].incl(handler)

proc removePeerEventHandler*(
    c: ConnManager, handler: PeerEventHandler, kind: PeerEventKind
) =
  c.peerEvents[kind].excl(handler)

proc triggerPeerEvents*(
    c: ConnManager, peerId: PeerId, event: PeerEvent
) {.async: (raises: [CancelledError]).} =
  trace "About to trigger peer events", peer = peerId
  if c.peerEvents[event.kind].len == 0:
    return

  try:
    trace "triggering peer events", peer = peerId, event = $event

    var peerEvents: seq[Future[void]]
    for h in c.peerEvents[event.kind]:
      peerEvents.add(h(peerId, event))

    checkFutures(await allFinished(peerEvents))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc: # handlers should not raise!
    warn "Exception in triggerPeerEvents", description = exc.msg, peer = peerId

proc expectConnection*(
    c: ConnManager, p: PeerId, dir: Direction
): Future[Muxer] {.async: (raises: [AlreadyExpectingConnectionError, CancelledError]).} =
  ## Wait for a peer to connect to us. This will bypass the `MaxConnectionsPerPeer`
  let key = (p, dir)
  if key in c.expectedConnectionsOverLimit:
    raise newException(
      AlreadyExpectingConnectionError,
      "Already expecting an incoming connection from that peer: " & shortLog(p),
    )

  let future = Future[Muxer].Raising([CancelledError]).init()
  c.expectedConnectionsOverLimit[key] = future

  try:
    return await future
  finally:
    c.expectedConnectionsOverLimit.del(key)

proc contains*(c: ConnManager, peerId: PeerId): bool =
  return c.muxerStore.contains(peerId)

proc contains*(c: ConnManager, muxer: Muxer): bool =
  if muxer.isNil:
    return false
  return c.muxerStore.contains(muxer)

proc closeMuxer(muxer: Muxer) {.async: (raises: [CancelledError]).} =
  trace "Cleaning up muxer", m = muxer

  await muxer.close()
  if not muxer.handler.isNil:
    try:
      await muxer.handler
    except CatchableError as exc:
      trace "Exception in close muxer handler", description = exc.msg
  trace "Cleaned up muxer", m = muxer

proc onPeerDisconnected(c: ConnManager, peerId: PeerId) {.async: (raises: []).} =
  if c.muxerStore.count(peerId) > 0:
    # onPeerDisconnected is called when we assumed that peer was disconnected.
    # but if peer did reconnect, we should not trigger the cleanup.
    return

  c.clearPeerReadyState(peerId)
  c.connectedAt.del(peerId)
  if not c.peerStore.isNil:
    c.peerStore.cleanup(peerId)
  libp2p_peers.set(c.muxerStore.countPeers.int64)
  await noCancel c.triggerPeerEvents(peerId, PeerEvent(kind: PeerEventKind.Left))

proc onClose(c: ConnManager, mux: Muxer) {.async: (raises: []).} =
  ## connection close event handler
  ##
  ## triggers the connections resource cleanup
  ##
  try:
    await mux.connection.join()
    trace "Connection closed, cleaning up", mux
  except CatchableError as exc:
    debug "Unexpected exception in connection manager's cleanup",
      description = exc.msg, mux
  finally:
    let peerId = mux.connection.peerId
    let removed = c.muxerStore.remove(mux)
    if removed and c.muxerStore.count(peerId) == 0:
      await c.onPeerDisconnected(peerId)
    await noCancel c.triggerConnEvent(
      peerId, ConnEvent(kind: ConnEventKind.Disconnected)
    )

proc selectMuxer*(c: ConnManager, peerId: PeerId, dir: Direction): Muxer =
  ## Select a connection for the provided peer and direction
  return c.muxerStore.selectMuxer(peerId, dir)

proc selectMuxer*(c: ConnManager, peerId: PeerId): Muxer =
  ## Select a connection for the provided peer, giving priority to outgoing connections.
  var mux = c.selectMuxer(peerId, Direction.Out)
  if mux.isNil:
    mux = c.selectMuxer(peerId, Direction.In)
  if mux.isNil:
    trace "connection not found", peerId
  return mux

proc triggerTrim(c: ConnManager) {.gcsafe, raises: [].}

proc storeMuxer*(
    c: ConnManager, muxer: Muxer
) {.async: (raises: [CancelledError, LPError]).} =
  ## store the connection and muxer

  if muxer.isNil:
    raise newException(LPError, "muxer cannot be nil")

  if muxer.connection.isNil:
    raise newException(LPError, "muxer's connection cannot be nil")

  if muxer.connection.closed or muxer.connection.atEof:
    raise newException(LPError, "Connection closed or EOF")

  let
    peerId = muxer.connection.peerId
    dir = muxer.connection.dir

  if c.muxerStore.count(peerId) > c.maxConnsPerPeer:
    let key = (peerId, dir)
    let expectedConn = c.expectedConnectionsOverLimit.getOrDefault(key)
    if expectedConn != nil and not expectedConn.finished:
      expectedConn.complete(muxer)
    else:
      debug "Too many connections for peer",
        conns = c.muxerStore.count(peerId), peerId, dir

      raise newTooManyConnectionsError()

  let isNewPeer = c.muxerStore.count(peerId) == 0

  if not c.muxerStore.add(muxer):
    raise newException(LPError, "muxer already stored")

  libp2p_peers.set(c.muxerStore.countPeers().int64)

  if c.watermark.isSome:
    if isNewPeer:
      c.connectedAt[peerId] = Moment.now()
    if c.muxerStore.countPeers() > c.watermark.get().highWater:
      c.triggerTrim()

  asyncSpawn c.onClose(muxer)

  let connectedEvent = c.triggerConnEvent(
    peerId, ConnEvent(kind: ConnEventKind.Connected, incoming: dir == Direction.In)
  )

  # this notifies that peer is ready once the Connected events have been started
  # but before waiting for them to be completed, avoiding deadlocks where a
  # connected handler would need inbound streams to progress.
  c.notifyPeerReady(peerId)
  await connectedEvent

  if isNewPeer:
    asyncSpawn c.triggerPeerEvents(
      peerId, PeerEvent(kind: PeerEventKind.Joined, initiator: dir == Direction.Out)
    )

  trace "Stored muxer",
    muxer, direction = $muxer.connection.dir, peers = c.muxerStore.countPeers()

proc getIncomingSlot*(
    c: ConnManager
): Future[ConnectionSlot] {.async: (raises: [CancelledError]).} =
  if c.inSema != nil:
    await c.inSema.acquire()
  return ConnectionSlot(connManager: c, direction: In)

proc getOutgoingSlot*(
    c: ConnManager, forceDial = false
): ConnectionSlot {.raises: [TooManyConnectionsError].} =
  if c.outSema != nil:
    if forceDial:
      # force dial by not blocking/waiting on acquire and
      # still calling acquire to track this connection.
      discard c.outSema.acquire()
    elif not c.outSema.tryAcquire():
      trace "Too many outgoing connections"
      raise newTooManyConnectionsError()
  return ConnectionSlot(connManager: c, direction: Out)

func semaphore(c: ConnManager, dir: Direction): AsyncSemaphore {.inline.} =
  return if dir == In: c.inSema else: c.outSema

proc availableSlots*(c: ConnManager, dir: Direction): int =
  let sema = semaphore(c, dir)
  if sema == nil:
    return ConnectionsUnlimited
  return sema.availableSlots

proc release*(cs: ConnectionSlot) =
  let sema = semaphore(cs.connManager, cs.direction)
  if sema == nil:
    return
  try:
    sema.release()
  except AsyncSemaphoreError:
    raiseAssert "semaphore released without acquire"

proc trackConnection*(cs: ConnectionSlot, conn: Connection) =
  proc semaphoreMonitor() {.async: (raises: [CancelledError]).} =
    try:
      await conn.join()
    except CatchableError as exc:
      trace "Exception in semaphore monitor, ignoring", description = exc.msg
    finally:
      cs.release()

  asyncSpawn semaphoreMonitor()

proc trackMuxer*(cs: ConnectionSlot, mux: Muxer) =
  cs.trackConnection(mux.connection)

proc getStream*(
    c: ConnManager, muxer: Muxer
): Future[Connection] {.async: (raises: [LPStreamError, MuxerError, CancelledError]).} =
  ## get a muxed stream for the passed muxer
  if not muxer.isNil:
    return await muxer.newStream()
  return nil

proc getStream*(
    c: ConnManager, peerId: PeerId
): Future[Connection] {.async: (raises: [LPStreamError, MuxerError, CancelledError]).} =
  ## get a muxed stream for the passed peer from any connection

  return await c.getStream(c.selectMuxer(peerId))

proc getStream*(
    c: ConnManager, peerId: PeerId, dir: Direction
): Future[Connection] {.async: (raises: [LPStreamError, MuxerError, CancelledError]).} =
  ## get a muxed stream for the passed peer from a connection with `dir`

  return await c.getStream(c.selectMuxer(peerId, dir))

proc dropPeer*(c: ConnManager, peerId: PeerId) {.async: (raises: [CancelledError]).} =
  ## drop connections and cleanup resources for peer

  trace "Dropping peer", peerId

  let muxers = c.muxerStore.remove(peerId)
  if muxers.len > 0:
    try:
      await allFutures(muxers.mapIt(closeMuxer(it)))
    finally:
      await noCancel c.onPeerDisconnected(peerId)

  trace "Peer dropped", peerId, connCount = muxers.len

proc protect*(c: ConnManager, peerId: PeerId, tag: string) =
  ## Mark `peerId` as protected from watermark trimming under `tag`.
  ## A peer remains protected as long as at least one tag is active.
  c.protectedPeers.mgetOrPut(peerId, initHashSet[string]()).incl(tag)

proc unprotect*(c: ConnManager, peerId: PeerId, tag: string): bool =
  ## Remove `tag` protection from `peerId`.
  ## Returns `true` if the peer is still protected via another tag, `false` otherwise.
  c.protectedPeers.withValue(peerId, tags):
    tags[].excl(tag)
    let isProtected = tags[].len > 0
    if not isProtected:
      c.protectedPeers.del(peerId)
    return isProtected
  return false

proc isProtected*(c: ConnManager, peerId: PeerId): bool =
  ## Returns `true` if `peerId` has at least one active protection tag.
  c.protectedPeers.withValue(peerId, tags):
    return tags[].len > 0
  return false

proc tagPeer*(c: ConnManager, peerId: PeerId, tag: string, value: int) =
  ## Set a static tag on `peerId`. Tags accumulate additively into the peer score.
  c.staticTags.mgetOrPut(peerId, initTable[string, int]())[tag] = value

proc untagPeer*(c: ConnManager, peerId: PeerId, tag: string) =
  ## Remove a static tag from `peerId`.
  c.staticTags.withValue(peerId, tags):
    tags[].del(tag)
    if tags[].len == 0:
      c.staticTags.del(peerId)

proc peerScore*(c: ConnManager, peerId: PeerId): int =
  ## Returns the total score for `peerId`:
  ##   outboundBonus (if peer has an outbound connection)
  ##   + sum of all static tag values
  ##   + sum of all current decaying tag values
  var score = 0
  if not c.selectMuxer(peerId, Direction.Out).isNil:
    score += c.scoringConfig.outboundBonus
  c.staticTags.withValue(peerId, tags):
    for _, v in tags[]:
      score += v
  c.decayingTags.withValue(peerId, tags):
    for _, tag in tags[]:
      score += tag.value
  return score

proc applyDecay(c: ConnManager) =
  let now = Moment.now()
  for peerId in c.decayingTags.keys.toSeq():
    c.decayingTags.withValue(peerId, innerTable):
      var tagsToRemove: seq[string]
      for name, tag in innerTable[].mpairs():
        if now >= tag.lastTick + tag.interval:
          tag.value = tag.decayFn(tag.value, now - tag.lastTick)
          tag.lastTick = now
          if tag.value <= 0:
            tagsToRemove.add(name)
      for name in tagsToRemove:
        innerTable[].del(name)
      if innerTable[].len == 0:
        c.decayingTags.del(peerId)

proc runDecayLoop(c: ConnManager) {.async: (raises: [CancelledError]).} =
  while c.decayingTags.len > 0:
    await sleepAsync(c.scoringConfig.decayResolution)
    c.applyDecay()
  c.decayLoopFut = nil

proc tagPeerDecaying*(
    c: ConnManager,
    peerId: PeerId,
    tag: string,
    value: int,
    interval: Duration,
    decayFn: DecayFn,
) =
  ## Attach an ephemeral tag to `peerId` with an initial `value`.
  ## The tag's value is updated by `decayFn` every `interval`. When the value
  ## drops to ≤0 the tag is removed automatically.
  doAssert interval > 0.seconds
  doAssert not decayFn.isNil

  let now = Moment.now()
  c.decayingTags.mgetOrPut(peerId, initTable[string, DecayingTagValue]())[tag] =
    DecayingTagValue(value: value, lastTick: now, interval: interval, decayFn: decayFn)
  if c.decayLoopFut.isNil or c.decayLoopFut.finished:
    c.decayLoopFut = c.runDecayLoop()

proc bumpDecayingTag*(c: ConnManager, peerId: PeerId, tag: string, delta: int) =
  ## Add `delta` to an existing decaying tag value. Clamps to 0 from below.
  c.decayingTags.withValue(peerId, tags):
    tags[].withValue(tag, t):
      t[].value = max(0, t[].value + delta)

proc removeDecayingTag*(c: ConnManager, peerId: PeerId, tag: string) =
  ## Immediately remove a decaying tag from `peerId`.
  c.decayingTags.withValue(peerId, tags):
    tags[].del(tag)
    if tags[].len == 0:
      c.decayingTags.del(peerId)

proc trimConnections(c: ConnManager) {.async: (raises: []).} =
  ## Closes peers until the total peer count is at or below `lowWater`.
  ## Skips peers within the grace period and peers that are protected.
  ## Prunes lowest-scoring peers first; uses connection age as a tiebreaker.
  libp2p_connmgr_trim_total.inc()
  let wm = c.watermark.get()
  let now = Moment.now()

  var candidates: seq[(int, Moment, PeerId)]
  for peerId in c.muxerStore.getPeers():
    let connTime = c.connectedAt.getOrDefault(peerId, now)
    if now - connTime < wm.gracePeriod:
      continue
    if c.isProtected(peerId):
      continue
    candidates.add((c.peerScore(peerId), connTime, peerId))

  candidates.sort(
    proc(a, b: (int, Moment, PeerId)): int =
      if a[0] != b[0]:
        cmp(a[0], b[0])
      else:
        a[1].cmp(b[1])
  )

  # initiate all drops concurrently and await them together.
  # this frees peer state immediately while letting the underlying
  # connection close futures run in parallel.
  var dropFuts: seq[Future[void]]
  for (_, _, peerId) in candidates:
    if c.muxerStore.countPeers() <= wm.lowWater:
      break
    dropFuts.add(c.dropPeer(peerId))
    libp2p_connmgr_pruned_peers_total.inc()

  try:
    await allFutures(dropFuts)
  except CancelledError:
    trace "watermark trim connection was cancelled"

  c.lastTrim = Moment.now()

proc triggerTrim(c: ConnManager) {.gcsafe, raises: [].} =
  ## Schedules a trim cycle if none is running and the silence period has elapsed.
  if not c.trimFut.isNil and not c.trimFut.finished:
    # trim is ongoing
    return

  c.watermark.withValue(wm):
    if Moment.now() - c.lastTrim < wm.silencePeriod:
      return
    c.trimFut = c.trimConnections()

proc close*(c: ConnManager) {.async: (raises: [CancelledError]).} =
  ## Cleanup resources for the connection manager.
  trace "Closing ConnManager"
  c.closed = true

  if not c.decayLoopFut.isNil:
    await c.decayLoopFut.cancelAndWait()

  if not c.trimFut.isNil:
    await c.trimFut.cancelAndWait()

  let expected = c.expectedConnectionsOverLimit
  c.expectedConnectionsOverLimit.clear()

  for _, fut in expected:
    await fut.cancelAndWait()

  let readyEvents = c.readyEvents
  for _, readyEvent in readyEvents:
    readyEvent.cancelSoon()
  c.readyEvents.clear()

  let muxed = c.muxerStore.getAll()
  c.muxerStore.clear()
  for peerId, muxers in muxed:
    if muxers.len > 0:
      await allFutures(muxers.mapIt(closeMuxer(it)))
      await c.onPeerDisconnected(peerId)

  trace "Closed ConnManager"

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.push raises: [].}

import std/[tables, sets, sequtils]
import pkg/[chronos, chronicles, metrics]
import peerinfo, peerstore, stream/connection, muxers/muxer, errors, muxer_store

logScope:
  topics = "libp2p connmanager"

declareGauge(libp2p_peers, "total connected peers")

const
  MaxConnections* = 50
  MaxConnectionsPerPeer* = 1

type
  TooManyConnectionsError* = object of LPError
  AlreadyExpectingConnectionError* = object of LPError

  ConnEventKind* {.pure.} = enum
    Connected
      # A connection was made and securely upgraded - there may be
      # more than one concurrent connection thus more than one upgrade
      # event per peer.
    Disconnected
      # Peer disconnected - this event is fired once per upgrade
      # when the associated connection is terminated.

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
    maxConnsPerPeer: int
    muxerStore: MuxerStore
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

  ConnectionSlot* = object
    connManager: ConnManager
    direction: Direction

proc newTooManyConnectionsError(): ref TooManyConnectionsError {.inline.} =
  result = newException(TooManyConnectionsError, "Too many connections")

proc newMaxTotal*(
    C: type ConnManager,
    maxConnections = MaxConnections,
    maxConnsPerPeer = MaxConnectionsPerPeer,
): ConnManager =
  ## Creates a `ConnManager` where incoming and outgoing connections share a
  ## single pool capped at `maxConnections`. Acquiring a slot for either
  ## direction draws from the same semaphore, so the combined total never
  ## exceeds `maxConnections`.
  doAssert maxConnections > 0, "`maxConnections` must be greater than 0"

  let sema = newAsyncSemaphore(maxConnections)
  C(
    muxerStore: MuxerStore.new(),
    maxConnsPerPeer: maxConnsPerPeer,
    maxConnectionsIn: maxConnections,
    maxConnectionsOut: maxConnections,
    inSema: sema,
    outSema: sema,
  )

proc newMaxInOut*(
    C: type ConnManager,
    maxIn: int,
    maxOut: int,
    maxConnsPerPeer = MaxConnectionsPerPeer,
): ConnManager =
  ## Creates a `ConnManager` where incoming and outgoing connections are limited
  ## independently: at most `maxIn` inbound and `maxOut` outbound connections
  ## may be open concurrently, each tracked by its own semaphore.
  doAssert maxIn > 0 and maxOut > 0,
    "ConnManager.newMaxInOut requires maxIn > 0 and maxOut > 0"

  C(
    muxerStore: MuxerStore.new(),
    maxConnsPerPeer: maxConnsPerPeer,
    maxConnectionsIn: maxIn,
    maxConnectionsOut: maxOut,
    inSema: newAsyncSemaphore(maxIn),
    outSema: newAsyncSemaphore(maxOut),
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
  ##
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
  ##

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
  ##
  return c.muxerStore.selectMuxer(peerId, dir)

proc selectMuxer*(c: ConnManager, peerId: PeerId): Muxer =
  ## Select a connection for the provided giving priority
  ## to outgoing connections
  ##

  var mux = c.selectMuxer(peerId, Direction.Out)
  if mux.isNil:
    mux = c.selectMuxer(peerId, Direction.In)
  if mux.isNil:
    trace "connection not found", peerId
  return mux

proc storeMuxer*(
    c: ConnManager, muxer: Muxer
) {.async: (raises: [CancelledError, LPError]).} =
  ## store the connection and muxer
  ##

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
  await c.inSema.acquire()
  return ConnectionSlot(connManager: c, direction: In)

proc getOutgoingSlot*(
    c: ConnManager, forceDial = false
): ConnectionSlot {.raises: [TooManyConnectionsError].} =
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
  return semaphore(c, dir).availableSlots

proc release*(cs: ConnectionSlot) =
  try:
    semaphore(cs.connManager, cs.direction).release()
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
  ##

  if not muxer.isNil:
    return await muxer.newStream()

proc getStream*(
    c: ConnManager, peerId: PeerId
): Future[Connection] {.async: (raises: [LPStreamError, MuxerError, CancelledError]).} =
  ## get a muxed stream for the passed peer from any connection
  ##

  return await c.getStream(c.selectMuxer(peerId))

proc getStream*(
    c: ConnManager, peerId: PeerId, dir: Direction
): Future[Connection] {.async: (raises: [LPStreamError, MuxerError, CancelledError]).} =
  ## get a muxed stream for the passed peer from a connection with `dir`
  ##

  return await c.getStream(c.selectMuxer(peerId, dir))

proc dropPeer*(c: ConnManager, peerId: PeerId) {.async: (raises: [CancelledError]).} =
  ## drop connections and cleanup resources for peer
  ##
  trace "Dropping peer", peerId

  let muxers = c.muxerStore.remove(peerId)
  if muxers.len > 0:
    try:
      await allFutures(muxers.mapIt(closeMuxer(it)))
    finally:
      await noCancel c.onPeerDisconnected(peerId)

  trace "Peer dropped", peerId, connCount = muxers.len

proc close*(c: ConnManager) {.async: (raises: [CancelledError]).} =
  ## cleanup resources for the connection
  ## manager
  ##

  trace "Closing ConnManager"
  c.closed = true

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

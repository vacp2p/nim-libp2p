# Nim-LibP2P
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

when (NimMajor, NimMinor) < (1, 4):
  {.push raises: [Defect].}
else:
  {.push raises: [].}

import std/[options, tables, sequtils, sets]
import pkg/[chronos, chronicles, metrics]
import peerinfo,
       peerstore,
       stream/connection,
       muxers/muxer,
       utils/semaphore,
       errors

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
    Connected,    # A connection was made and securely upgraded - there may be
                  # more than one concurrent connection thus more than one upgrade
                  # event per peer.

    Disconnected  # Peer disconnected - this event is fired once per upgrade
                  # when the associated connection is terminated.

  ConnEvent* = object
    case kind*: ConnEventKind
    of ConnEventKind.Connected:
      incoming*: bool
    else:
      discard

  ConnEventHandler* =
    proc(peerId: PeerId, event: ConnEvent): Future[void]
      {.gcsafe, raises: [Defect].}

  PeerEventKind* {.pure.} = enum
    Left,
    Joined

  PeerEvent* = object
    case kind*: PeerEventKind
      of PeerEventKind.Joined:
        initiator*: bool
      else:
        discard

  PeerEventHandler* =
    proc(peerId: PeerId, event: PeerEvent): Future[void] {.gcsafe, raises: [Defect].}

  ConnManager* = ref object of RootObj
    maxConnsPerPeer: int
    inSema*: AsyncSemaphore
    outSema*: AsyncSemaphore
    muxed: Table[PeerId, seq[Muxer]]
    connEvents: array[ConnEventKind, OrderedSet[ConnEventHandler]]
    peerEvents: array[PeerEventKind, OrderedSet[PeerEventHandler]]
    expectedConnectionsOverLimit*: Table[(PeerId, Direction), Future[Muxer]]
    peerStore*: PeerStore

  ConnectionSlot* = object
    connManager: ConnManager
    direction: Direction

proc newTooManyConnectionsError(): ref TooManyConnectionsError {.inline.} =
  result = newException(TooManyConnectionsError, "Too many connections")

proc new*(C: type ConnManager,
           maxConnsPerPeer = MaxConnectionsPerPeer,
           maxConnections = MaxConnections,
           maxIn = -1,
           maxOut = -1): ConnManager =
  var inSema, outSema: AsyncSemaphore
  if maxIn > 0 or maxOut > 0:
    inSema = newAsyncSemaphore(maxIn)
    outSema = newAsyncSemaphore(maxOut)
  elif maxConnections > 0:
    inSema = newAsyncSemaphore(maxConnections)
    outSema = inSema
  else:
    raiseAssert "Invalid connection counts!"

  C(maxConnsPerPeer: maxConnsPerPeer,
    inSema: inSema,
    outSema: outSema)

proc connCount*(c: ConnManager, peerId: PeerId): int =
  c.muxed.getOrDefault(peerId).len

proc connectedPeers*(c: ConnManager, dir: Direction): seq[PeerId] =
  var peers = newSeq[PeerId]()
  for peerId, mux in c.muxed:
    if mux.anyIt(it.connection.dir == dir):
      peers.add(peerId)
  return peers

proc getConnections*(c: ConnManager): Table[PeerId, seq[Muxer]] =
  return c.muxed

proc addConnEventHandler*(c: ConnManager,
                          handler: ConnEventHandler,
                          kind: ConnEventKind) =
  ## Add peer event handler - handlers must not raise exceptions!
  ##

  try:
    if isNil(handler): return
    c.connEvents[kind].incl(handler)
  except Exception as exc:
    # TODO: there is an Exception being raised
    # somewhere in the depths of the std.
    # Might be related to https://github.com/nim-lang/Nim/issues/17382

    raiseAssert exc.msg

proc removeConnEventHandler*(c: ConnManager,
                             handler: ConnEventHandler,
                             kind: ConnEventKind) =
  try:
    c.connEvents[kind].excl(handler)
  except Exception as exc:
    # TODO: there is an Exception being raised
    # somewhere in the depths of the std.
    # Might be related to https://github.com/nim-lang/Nim/issues/17382

    raiseAssert exc.msg

proc triggerConnEvent*(c: ConnManager,
                       peerId: PeerId,
                       event: ConnEvent) {.async, gcsafe.} =
  try:
    trace "About to trigger connection events", peer = peerId
    if c.connEvents[event.kind].len() > 0:
      trace "triggering connection events", peer = peerId, event = $event.kind
      var connEvents: seq[Future[void]]
      for h in c.connEvents[event.kind]:
        connEvents.add(h(peerId, event))

      checkFutures(await allFinished(connEvents))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    warn "Exception in triggerConnEvents",
      msg = exc.msg, peer = peerId, event = $event

proc addPeerEventHandler*(c: ConnManager,
                          handler: PeerEventHandler,
                          kind: PeerEventKind) =
  ## Add peer event handler - handlers must not raise exceptions!
  ##

  if isNil(handler): return
  try:
    c.peerEvents[kind].incl(handler)
  except Exception as exc:
    # TODO: there is an Exception being raised
    # somewhere in the depths of the std.
    # Might be related to https://github.com/nim-lang/Nim/issues/17382

    raiseAssert exc.msg

proc removePeerEventHandler*(c: ConnManager,
                             handler: PeerEventHandler,
                             kind: PeerEventKind) =
  try:
    c.peerEvents[kind].excl(handler)
  except Exception as exc:
    # TODO: there is an Exception being raised
    # somewhere in the depths of the std.
    # Might be related to https://github.com/nim-lang/Nim/issues/17382

    raiseAssert exc.msg

proc triggerPeerEvents*(c: ConnManager,
                        peerId: PeerId,
                        event: PeerEvent) {.async, gcsafe.} =

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
    warn "Exception in triggerPeerEvents", exc = exc.msg, peer = peerId

proc expectConnection*(c: ConnManager, p: PeerId, dir: Direction): Future[Muxer] {.async.} =
  ## Wait for a peer to connect to us. This will bypass the `MaxConnectionsPerPeer`
  let key = (p, dir)
  if key in c.expectedConnectionsOverLimit:
    raise newException(AlreadyExpectingConnectionError, "Already expecting an incoming connection from that peer")

  let future = newFuture[Muxer]()
  c.expectedConnectionsOverLimit[key] = future

  try:
    return await future
  finally:
    c.expectedConnectionsOverLimit.del(key)

proc contains*(c: ConnManager, peerId: PeerId): bool =
  peerId in c.muxed

proc contains*(c: ConnManager, muxer: Muxer): bool =
  ## checks if a muxer is being tracked by the connection
  ## manager
  ##

  if isNil(muxer):
    return false

  let conn = muxer.connection
  return muxer in c.muxed.getOrDefault(conn.peerId)

proc closeMuxer(muxer: Muxer) {.async.} =
  trace "Cleaning up muxer", m = muxer

  await muxer.close()
  if not(isNil(muxer.handler)):
    try:
      await muxer.handler # TODO noraises?
    except CatchableError as exc:
      trace "Exception in close muxer handler", exc = exc.msg
  trace "Cleaned up muxer", m = muxer

proc muxCleanup(c: ConnManager, mux: Muxer) {.async.} =
  try:
    trace "Triggering disconnect events", mux
    let peerId = mux.connection.peerId

    let muxers = c.muxed.getOrDefault(peerId).filterIt(it != mux)
    if muxers.len > 0:
      c.muxed[peerId] = muxers
    else:
      c.muxed.del(peerId)
      libp2p_peers.set(c.muxed.len.int64)
      await c.triggerPeerEvents(peerId, PeerEvent(kind: PeerEventKind.Left))

      if not(c.peerStore.isNil):
        c.peerStore.cleanup(peerId)

    await c.triggerConnEvent(
      peerId, ConnEvent(kind: ConnEventKind.Disconnected))
  except CatchableError as exc:
    # This is top-level procedure which will work as separate task, so it
    # do not need to propagate CancelledError and should handle other errors
    warn "Unexpected exception peer cleanup handler",
      mux, msg = exc.msg

proc onClose(c: ConnManager, mux: Muxer) {.async.} =
  ## connection close even handler
  ##
  ## triggers the connections resource cleanup
  ##
  try:
    await mux.connection.join()
    trace "Connection closed, cleaning up", mux
  except CatchableError as exc:
    debug "Unexpected exception in connection manager's cleanup",
          errMsg = exc.msg, mux
  finally:
    await c.muxCleanup(mux)

proc selectMuxer*(c: ConnManager,
                peerId: PeerId,
                dir: Direction): Muxer =
  ## Select a connection for the provided peer and direction
  ##
  let conns = toSeq(
    c.muxed.getOrDefault(peerId))
    .filterIt( it.connection.dir == dir )

  if conns.len > 0:
    return conns[0]

proc selectMuxer*(c: ConnManager, peerId: PeerId): Muxer =
  ## Select a connection for the provided giving priority
  ## to outgoing connections
  ##

  var mux = c.selectMuxer(peerId, Direction.Out)
  if isNil(mux):
    mux = c.selectMuxer(peerId, Direction.In)
  if isNil(mux):
    trace "connection not found", peerId
  return mux

proc storeMuxer*(c: ConnManager,
                 muxer: Muxer)
                 {.raises: [Defect, CatchableError].} =
  ## store the connection and muxer
  ##

  if isNil(muxer):
    raise newException(LPError, "muxer cannot be nil")

  if isNil(muxer.connection):
    raise newException(LPError, "muxer's connection cannot be nil")

  if muxer.connection.closed or muxer.connection.atEof:
    raise newException(LPError, "Connection closed or EOF")

  let
    peerId = muxer.connection.peerId
    dir = muxer.connection.dir

  # we use getOrDefault in the if below instead of [] to avoid the KeyError
  if c.muxed.getOrDefault(peerId).len > c.maxConnsPerPeer:
    let key = (peerId, dir)
    let expectedConn = c.expectedConnectionsOverLimit.getOrDefault(key)
    if expectedConn != nil and not expectedConn.finished:
        expectedConn.complete(muxer)
    else:
      debug "Too many connections for peer",
        conns = c.muxed.getOrDefault(peerId).len

      raise newTooManyConnectionsError()

  assert muxer notin c.muxed.getOrDefault(peerId)

  let
    newPeer = peerId notin c.muxed
  assert newPeer or c.muxed[peerId].len > 0
  c.muxed.mgetOrPut(peerId, newSeq[Muxer]()).add(muxer)
  libp2p_peers.set(c.muxed.len.int64)

  asyncSpawn c.triggerConnEvent(
    peerId, ConnEvent(kind: ConnEventKind.Connected, incoming: dir == Direction.In))

  if newPeer:
    asyncSpawn c.triggerPeerEvents(
      peerId, PeerEvent(kind: PeerEventKind.Joined, initiator: dir == Direction.Out))

  asyncSpawn c.onClose(muxer)

  trace "Stored muxer",
    muxer, direction = $muxer.connection.dir, peers = c.muxed.len

proc getIncomingSlot*(c: ConnManager): Future[ConnectionSlot] {.async.} =
  await c.inSema.acquire()
  return ConnectionSlot(connManager: c, direction: In)

proc getOutgoingSlot*(c: ConnManager, forceDial = false): ConnectionSlot {.raises: [Defect, TooManyConnectionsError].} =
  if forceDial:
    c.outSema.forceAcquire()
  elif not c.outSema.tryAcquire():
    trace "Too many outgoing connections!", count = c.outSema.count,
                                            max = c.outSema.size
    raise newTooManyConnectionsError()
  return ConnectionSlot(connManager: c, direction: Out)

proc slotsAvailable*(c: ConnManager, dir: Direction): int =
  case dir:
    of Direction.In:
      return c.inSema.count
    of Direction.Out:
      return c.outSema.count

proc release*(cs: ConnectionSlot) =
  if cs.direction == In:
    cs.connManager.inSema.release()
  else:
    cs.connManager.outSema.release()

proc trackConnection*(cs: ConnectionSlot, conn: Connection) =
  if isNil(conn):
    cs.release()
    return

  proc semaphoreMonitor() {.async.} =
    try:
      await conn.join()
    except CatchableError as exc:
      trace "Exception in semaphore monitor, ignoring", exc = exc.msg

    cs.release()

  asyncSpawn semaphoreMonitor()

proc trackMuxer*(cs: ConnectionSlot, mux: Muxer) =
  if isNil(mux):
    cs.release()
    return
  cs.trackConnection(mux.connection)

proc getStream*(c: ConnManager,
                muxer: Muxer): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed muxer
  ##

  if not(isNil(muxer)):
    return await muxer.newStream()

proc getStream*(c: ConnManager,
                peerId: PeerId): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed peer from any connection
  ##

  return await c.getStream(c.selectMuxer(peerId))

proc getStream*(c: ConnManager,
                peerId: PeerId,
                dir: Direction): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed peer from a connection with `dir`
  ##

  return await c.getStream(c.selectMuxer(peerId, dir))


proc dropPeer*(c: ConnManager, peerId: PeerId) {.async.} =
  ## drop connections and cleanup resources for peer
  ##
  trace "Dropping peer", peerId
  let muxers = c.muxed.getOrDefault(peerId)

  for muxer in muxers:
    await closeMuxer(muxer)

  trace "Peer dropped", peerId

proc close*(c: ConnManager) {.async.} =
  ## cleanup resources for the connection
  ## manager
  ##

  trace "Closing ConnManager"
  let muxed = c.muxed
  c.muxed.clear()

  let expected = c.expectedConnectionsOverLimit
  c.expectedConnectionsOverLimit.clear()

  for _, fut in expected:
    await fut.cancelAndWait()

  for _, muxers in muxed:
    for mux in muxers:
      await closeMuxer(mux)

  trace "Closed ConnManager"


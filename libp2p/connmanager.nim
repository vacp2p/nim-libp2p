## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

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

  ConnProvider* = proc(): Future[Connection]
    {.gcsafe, closure, raises: [Defect].}

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
    Identified,
    Joined

  PeerEvent* = object
    case kind*: PeerEventKind
      of PeerEventKind.Joined:
        initiator*: bool
      else:
        discard

  PeerEventHandler* =
    proc(peerId: PeerId, event: PeerEvent): Future[void] {.gcsafe, raises: [Defect].}

  MuxerHolder = object
    muxer: Muxer
    handle: Future[void]

  ConnManager* = ref object of RootObj
    maxConnsPerPeer: int
    inSema*: AsyncSemaphore
    outSema*: AsyncSemaphore
    conns: Table[PeerId, HashSet[Connection]]
    muxed: Table[Connection, MuxerHolder]
    connEvents: array[ConnEventKind, OrderedSet[ConnEventHandler]]
    peerEvents: array[PeerEventKind, OrderedSet[PeerEventHandler]]
    peerStore*: PeerStore

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
  c.conns.getOrDefault(peerId).len

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
    let count = c.connCount(peerId)
    if event.kind == PeerEventKind.Joined and count != 1:
      trace "peer already joined", peer = peerId, event = $event
      return
    elif event.kind == PeerEventKind.Left and count != 0:
      trace "peer still connected or already left", peer = peerId, event = $event
      return

    trace "triggering peer events", peer = peerId, event = $event

    var peerEvents: seq[Future[void]]
    for h in c.peerEvents[event.kind]:
      peerEvents.add(h(peerId, event))

    checkFutures(await allFinished(peerEvents))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc: # handlers should not raise!
    warn "Exception in triggerPeerEvents", exc = exc.msg, peer = peerId

proc contains*(c: ConnManager, conn: Connection): bool =
  ## checks if a connection is being tracked by the
  ## connection manager
  ##

  if isNil(conn):
    return

  return conn in c.conns.getOrDefault(conn.peerId)

proc contains*(c: ConnManager, peerId: PeerId): bool =
  peerId in c.conns

proc contains*(c: ConnManager, muxer: Muxer): bool =
  ## checks if a muxer is being tracked by the connection
  ## manager
  ##

  if isNil(muxer):
    return

  let conn = muxer.connection
  if conn notin c:
    return

  if conn notin c.muxed:
    return

  return muxer == c.muxed.getOrDefault(conn).muxer

proc closeMuxerHolder(muxerHolder: MuxerHolder) {.async.} =
  trace "Cleaning up muxer", m = muxerHolder.muxer

  await muxerHolder.muxer.close()
  if not(isNil(muxerHolder.handle)):
    try:
      await muxerHolder.handle # TODO noraises?
    except CatchableError as exc:
      trace "Exception in close muxer handler", exc = exc.msg
  trace "Cleaned up muxer", m = muxerHolder.muxer

proc delConn(c: ConnManager, conn: Connection) =
  let peerId = conn.peerId
  c.conns.withValue(peerId, peerConns):
    peerConns[].excl(conn)

    if peerConns[].len == 0:
      c.conns.del(peerId) # invalidates `peerConns`

    libp2p_peers.set(c.conns.len.int64)
    trace "Removed connection", conn

proc cleanupConn(c: ConnManager, conn: Connection) {.async.} =
  ## clean connection's resources such as muxers and streams

  if isNil(conn):
    trace "Wont cleanup a nil connection"
    return

  # Remove connection from all tables without async breaks
  var muxer = some(MuxerHolder())
  if not c.muxed.pop(conn, muxer.get()):
    muxer = none(MuxerHolder)

  delConn(c, conn)

  try:
    if muxer.isSome:
      await closeMuxerHolder(muxer.get())
  finally:
    await conn.close()

  trace "Connection cleaned up", conn

proc onConnUpgraded(c: ConnManager, conn: Connection) {.async.} =
  try:
    trace "Triggering connect events", conn
    conn.upgrade()

    let peerId = conn.peerId
    await c.triggerPeerEvents(
      peerId, PeerEvent(kind: PeerEventKind.Joined, initiator: conn.dir == Direction.Out))

    await c.triggerConnEvent(
      peerId, ConnEvent(kind: ConnEventKind.Connected, incoming: conn.dir == Direction.In))
  except CatchableError as exc:
    # This is top-level procedure which will work as separate task, so it
    # do not need to propagate CancelledError and should handle other errors
    warn "Unexpected exception in switch peer connection cleanup",
      conn, msg = exc.msg

proc peerCleanup(c: ConnManager, conn: Connection) {.async.} =
  try:
    trace "Triggering disconnect events", conn
    let peerId = conn.peerId
    await c.triggerConnEvent(
      peerId, ConnEvent(kind: ConnEventKind.Disconnected))
    await c.triggerPeerEvents(peerId, PeerEvent(kind: PeerEventKind.Left))
  except CatchableError as exc:
    # This is top-level procedure which will work as separate task, so it
    # do not need to propagate CancelledError and should handle other errors
    warn "Unexpected exception peer cleanup handler",
      conn, msg = exc.msg

proc onClose(c: ConnManager, conn: Connection) {.async.} =
  ## connection close even handler
  ##
  ## triggers the connections resource cleanup
  ##
  try:
    await conn.join()
    trace "Connection closed, cleaning up", conn
    await c.cleanupConn(conn)
  except CancelledError:
    # This is top-level procedure which will work as separate task, so it
    # do not need to propagate CancelledError.
    debug "Unexpected cancellation in connection manager's cleanup", conn
  except CatchableError as exc:
    debug "Unexpected exception in connection manager's cleanup",
          errMsg = exc.msg, conn
  finally:
    trace "Triggering peerCleanup", conn
    asyncSpawn c.peerCleanup(conn)

proc selectConn*(c: ConnManager,
                peerId: PeerId,
                dir: Direction): Connection =
  ## Select a connection for the provided peer and direction
  ##
  let conns = toSeq(
    c.conns.getOrDefault(peerId))
    .filterIt( it.dir == dir )

  if conns.len > 0:
    return conns[0]

proc selectConn*(c: ConnManager, peerId: PeerId): Connection =
  ## Select a connection for the provided giving priority
  ## to outgoing connections
  ##

  var conn = c.selectConn(peerId, Direction.Out)
  if isNil(conn):
    conn = c.selectConn(peerId, Direction.In)
  if isNil(conn):
    trace "connection not found", peerId

  return conn

proc selectMuxer*(c: ConnManager, conn: Connection): Muxer =
  ## select the muxer for the provided connection
  ##

  if isNil(conn):
    return

  if conn in c.muxed:
    return c.muxed.getOrDefault(conn).muxer
  else:
    debug "no muxer for connection", conn

proc storeConn*(c: ConnManager, conn: Connection)
  {.raises: [Defect, LPError].} =
  ## store a connection
  ##

  if isNil(conn):
    raise newException(LPError, "Connection cannot be nil")

  if conn.closed or conn.atEof:
    raise newException(LPError, "Connection closed or EOF")

  let peerId = conn.peerId
  if c.conns.getOrDefault(peerId).len > c.maxConnsPerPeer:
    debug "Too many connections for peer",
      conn, conns = c.conns.getOrDefault(peerId).len

    raise newTooManyConnectionsError()

  c.conns.mgetOrPut(peerId, HashSet[Connection]()).incl(conn)
  libp2p_peers.set(c.conns.len.int64)

  # Launch on close listener
  # All the errors are handled inside `onClose()` procedure.
  asyncSpawn c.onClose(conn)

  trace "Stored connection",
    conn, direction = $conn.dir, connections = c.conns.len

proc trackConn(c: ConnManager,
               provider: ConnProvider,
               sema: AsyncSemaphore):
               Future[Connection] {.async.} =
  var conn: Connection
  try:
    conn = await provider()

    if isNil(conn):
      return

    trace "Got connection", conn

    proc semaphoreMonitor() {.async.} =
      try:
        await conn.join()
      except CatchableError as exc:
        trace "Exception in semaphore monitor, ignoring", exc = exc.msg

      sema.release()

    asyncSpawn semaphoreMonitor()
  except CatchableError as exc:
    trace "Exception tracking connection", exc = exc.msg
    if not isNil(conn):
      await conn.close()

    raise exc

  return conn

proc trackIncomingConn*(c: ConnManager,
                        provider: ConnProvider):
                        Future[Connection] {.async.} =
  ## await for a connection slot before attempting
  ## to call the connection provider
  ##

  var conn: Connection
  try:
    trace "Tracking incoming connection"
    await c.inSema.acquire()
    conn = await c.trackConn(provider, c.inSema)
    if isNil(conn):
      trace "Couldn't acquire connection, releasing semaphore slot", dir = $Direction.In
      c.inSema.release()

    return conn
  except CatchableError as exc:
    trace "Exception tracking connection", exc = exc.msg
    c.inSema.release()
    raise exc

proc trackOutgoingConn*(c: ConnManager,
                        provider: ConnProvider,
                        forceDial = false):
                        Future[Connection] {.async.} =
  ## try acquiring a connection if all slots
  ## are already taken, raise TooManyConnectionsError
  ## exception
  ##

  trace "Tracking outgoing connection", count = c.outSema.count,
                                        max = c.outSema.size

  if forceDial:
    c.outSema.forceAcquire()
  elif not c.outSema.tryAcquire():
    trace "Too many outgoing connections!", count = c.outSema.count,
                                            max = c.outSema.size
    raise newTooManyConnectionsError()

  var conn: Connection
  try:
    conn = await c.trackConn(provider, c.outSema)
    if isNil(conn):
      trace "Couldn't acquire connection, releasing semaphore slot", dir = $Direction.Out
      c.outSema.release()

    return conn
  except CatchableError as exc:
    trace "Exception tracking connection", exc = exc.msg
    c.outSema.release()
    raise exc

proc storeMuxer*(c: ConnManager,
                 muxer: Muxer,
                 handle: Future[void] = nil)
                 {.raises: [Defect, CatchableError].} =
  ## store the connection and muxer
  ##

  if isNil(muxer):
    raise newException(CatchableError, "muxer cannot be nil")

  if isNil(muxer.connection):
    raise newException(CatchableError, "muxer's connection cannot be nil")

  if muxer.connection notin c:
    raise newException(CatchableError, "cant add muxer for untracked connection")

  c.muxed[muxer.connection] = MuxerHolder(
    muxer: muxer,
    handle: handle)

  trace "Stored muxer",
    muxer, handle = not handle.isNil, connections = c.conns.len

  asyncSpawn c.onConnUpgraded(muxer.connection)

proc getStream*(c: ConnManager,
                peerId: PeerId,
                dir: Direction): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the provided peer
  ## with the given direction
  ##

  let muxer = c.selectMuxer(c.selectConn(peerId, dir))
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getStream*(c: ConnManager,
                peerId: PeerId): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed peer from any connection
  ##

  let muxer = c.selectMuxer(c.selectConn(peerId))
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getStream*(c: ConnManager,
                conn: Connection): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed connection
  ##

  let muxer = c.selectMuxer(conn)
  if not(isNil(muxer)):
    return await muxer.newStream()

proc dropPeer*(c: ConnManager, peerId: PeerId) {.async.} =
  ## drop connections and cleanup resources for peer
  ##
  trace "Dropping peer", peerId
  let conns = c.conns.getOrDefault(peerId)
  for conn in conns:
    trace  "Removing connection", conn
    delConn(c, conn)

  var muxers: seq[MuxerHolder]
  for conn in conns:
    if conn in c.muxed:
      muxers.add c.muxed[conn]
      c.muxed.del(conn)

  for muxer in muxers:
    await closeMuxerHolder(muxer)

  for conn in conns:
    await conn.close()
    trace "Dropped peer", peerId

  trace "Peer dropped", peerId

proc close*(c: ConnManager) {.async.} =
  ## cleanup resources for the connection
  ## manager
  ##

  trace "Closing ConnManager"
  let conns = c.conns
  c.conns.clear()

  let muxed = c.muxed
  c.muxed.clear()

  for _, muxer in muxed:
    await closeMuxerHolder(muxer)

  for _, conns2 in conns:
    for conn in conns2:
      await conn.close()

  trace "Closed ConnManager"

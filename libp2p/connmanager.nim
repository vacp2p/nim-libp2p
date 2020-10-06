## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[options, tables, sequtils, sets, sugar]
import chronos, chronicles, metrics
import peerinfo,
       stream/connection,
       muxers/muxer,
       utils/semaphore,
       errors

logScope:
  topics = "libp2p connmanager"

declareGauge(libp2p_peers, "total connected peers")

const
  MaxConnectionsPerPeer = 5

type
  TooManyConnections* = object of CatchableError

  ConnProvider* = proc(): Future[Connection] {.gcsafe, closure.}

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
    proc(peerId: PeerID, event: ConnEvent): Future[void] {.gcsafe.}

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
    proc(peerId: PeerID, event: PeerEvent): Future[void] {.gcsafe.}

  MuxerHolder = object
    muxer: Muxer
    handle: Future[void]

  ConnHolder = object
    conn: Connection
    evtHandle: Future[void]

  ConnManager* = ref object of RootObj
    maxConns: int
    maxPeerConns: int
    connSemaphore*: AsyncSemaphore
    muxed: Table[Connection, MuxerHolder]
    conns: seq[ConnHolder]
    connEvents: Table[ConnEventKind, OrderedSet[ConnEventHandler]]
    peerEvents: Table[PeerEventKind, OrderedSet[PeerEventHandler]]

proc newTooManyConnections(): ref TooManyConnections {.inline.} =
  result = newException(TooManyConnections, "too many connections for peer")

proc init*(C: type ConnManager,
           maxConns: int = MaxConnections,
           maxPeerConns: int = MaxConnectionsPerPeer): ConnManager =
  C(maxConns: maxConns,
    maxPeerConns: maxPeerConns,
    muxed: initTable[Connection, MuxerHolder](),
    connSemaphore: AsyncSemaphore.init(maxConns))

proc connCount*(c: ConnManager, peerId: PeerID): int =
  c.conns
  .filter((h) =>
      (not isNil(h.conn.peerInfo) and
      h.conn.peerInfo.peerId == peerId)
  ).len

proc peerCount*(c: ConnManager): int =
  c.conns
  .filter((c) => not isNil(c.conn.peerInfo))
  .deduplicate()
  .len

proc addConnEventHandler*(c: ConnManager,
                          handler: ConnEventHandler,
                          kind: ConnEventKind) =
  ## Add peer event handler - handlers must not raise exceptions!
  ##

  if isNil(handler): return
  c.connEvents.mgetOrPut(kind,
    initOrderedSet[ConnEventHandler]()).incl(handler)

proc removeConnEventHandler*(c: ConnManager,
                             handler: ConnEventHandler,
                             kind: ConnEventKind) =
  c.connEvents.withValue(kind, handlers) do:
    handlers[].excl(handler)

proc triggerConnEvent*(c: ConnManager,
                       peerId: PeerID,
                       event: ConnEvent) {.async, gcsafe.} =
  try:
    if event.kind in c.connEvents:
      var connEvents: seq[Future[void]]
      for h in c.connEvents[event.kind]:
        connEvents.add(h(peerId, event))

      checkFutures(await allFinished(connEvents))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc: # handlers should not raise!
    warn "Exception in triggerConnEvents",
      msg = exc.msg, peerId, event = $event

proc addPeerEventHandler*(c: ConnManager,
                          handler: PeerEventHandler,
                          kind: PeerEventKind) =
  ## Add peer event handler - handlers must not raise exceptions!
  ##

  if isNil(handler): return
  c.peerEvents.mgetOrPut(kind,
    initOrderedSet[PeerEventHandler]()).incl(handler)

proc removePeerEventHandler*(c: ConnManager,
                             handler: PeerEventHandler,
                             kind: PeerEventKind) =
  c.peerEvents.withValue(kind, handlers) do:
    handlers[].excl(handler)

proc triggerPeerEvents*(c: ConnManager,
                        peerId: PeerID,
                        event: PeerEvent) {.async, gcsafe.} =

  trace "About to trigger peer events", peer = peerId
  if event.kind notin c.peerEvents:
    return

  try:
    let count = c.connCount(peerId)
    if event.kind == PeerEventKind.Joined and count != 1:
      trace "peer already joined", peerId, event = $event
      return
    elif event.kind == PeerEventKind.Left and count != 0:
      trace "peer still connected or already left", peerId, event = $event
      return

    trace "triggering peer events", peerId, event = $event

    var peerEvents: seq[Future[void]]
    for h in c.peerEvents[event.kind]:
      peerEvents.add(h(peerId, event))

    checkFutures(await allFinished(peerEvents))
  except CancelledError as exc:
    raise exc
  except CatchableError as exc: # handlers should not raise!
    warn "Exception in triggerPeerEvents", exc = exc.msg, peerId

proc contains*(c: ConnManager, conn: Connection): bool =
  ## checks if a connection is being tracked by the
  ## connection manager
  ##

  if isNil(conn):
    return

  if isNil(conn.peerInfo):
    return

  return conn in c.conns.getOrDefault(conn.peerInfo.peerId)

proc contains*(c: ConnManager, peerId: PeerID): bool =
  c.connCount(peerId) > 0

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

  return muxer == c.muxed[conn].muxer

proc closeMuxerHolder(muxerHolder: MuxerHolder) {.async.} =
  trace "Cleaning up muxer", m = muxerHolder.muxer

  await muxerHolder.muxer.close()
  if not(isNil(muxerHolder.handle)):
    await muxerHolder.handle # TODO noraises?
  trace "Cleaned up muxer", m = muxerHolder.muxer

proc delConn(c: ConnManager, conn: Connection) =
  let peerId = conn.peerInfo.peerId
  if peerId in c.conns:
    c.conns[peerId].excl(conn)

    if c.conns[peerId].len == 0:
      c.conns.del(peerId)

    libp2p_peers.set(c.conns.len.int64)
    trace "Removed connection", conn

proc cleanupConn(c: ConnManager, conn: Connection) {.async.} =
  ## clean connection's resources such as muxers and streams
  ##

  if isNil(conn):
    return

  var muxer = none(MuxerHolder)
  if not isNil(conn.peerInfo):
    # Remove connection from all tables without async breaks
    muxer = some(MuxerHolder())
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

    let peerId = conn.peerInfo.peerId
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
    let peerId = conn.peerInfo.peerId
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
    # don't put the join in the try
    # to prevent the finally from
    # firing on canceled futures
    try:
      trace "Connection closed, cleaning up", conn
      await c.cleanupConn(conn)
    finally:
      c.connSemaphore.release()
  except CancelledError:
    # This is top-level procedure which will work as separate task, so it
    # do not need to propagate CancelledError.
    debug "Canceling close event for connection", conn
  except CatchableError as exc:
    debug "Unexpected exception in connection manager's cleanup",
          errMsg = exc.msg, conn
  finally:
    trace "Triggering peerCleanup", conn
    asyncSpawn c.peerCleanup(conn)

proc selectConn(c: ConnManager,
                 peerId: PeerID,
                 dir: Direction): Connection =
  ## Select a connection for the provided peer and direction
  ##

  let conns = c.conns
    .filter((h) =>
      (not isNil(h.conn.peerInfo) and
        h.conn.peerInfo.peerId == peerId))
    .filterIt( it.conn.dir == dir )

  if conns.len > 0:
    return conns[0].conn

proc selectConn(c: ConnManager, peerId: PeerID): Connection =
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
    return c.muxed[conn].muxer
  else:
    debug "no muxer for connection", conn

proc selectMuxer*(c: ConnManager,
                  peerId: PeerID,
                  dir: Direction): Muxer =
  ## select a muxer for a peer with the specified
  ## direction
  ##

  let conns = toSeq(c.muxed.keys).filterIt(
    it.peerInfo.peerId == peerId and it.dir == dir
  )

  if conns.len > 0:
    return c.selectMuxer(conns[0])

proc selectMuxer*(c: ConnManager, peerId: PeerID): Muxer =
  ## select a muxer for a peer
  ##

  var muxer = c.selectMuxer(peerId, Direction.Out)
  if isNil(muxer):
    muxer = c.selectMuxer(peerId, Direction.In)

  if isNil(muxer):
    trace "Muxer not found", peerId

  return muxer

proc updateConn*(c: ConnManager, a, b: Connection) =
  for h in c.conns.mitems:
    if h.conn == a:
      h.conn = b
      h.evtHandle.cancel()
      h.evtHandle = c.onClose(b)

      debug "Updated connection", conn = h.conn
      if not isNil(b.peerInfo):
        if c.connCount(b.peerInfo.peerId) > c.maxPeerConns:
          raise newTooManyConnections()

        libp2p_peers.set(c.peerCount().int64)

      return

  raise newException(CatchableError, "No connection to update!")

proc storeConn*(c: ConnManager, conn: Connection) =
  ## store a connection
  ##

  if isNil(conn):
    raise newException(CatchableError, "Connection cannot be nil")

  if not isNil(conn.peerInfo) and
    c.connCount(conn.peerInfo.peerId) > c.maxPeerConns:
    raise newTooManyConnections()

  c.conns.add(ConnHolder(
    conn: conn,
    evtHandle: c.onClose(conn)))

  # All the errors are handled inside `onClose()` procedure.
  if not isNil(conn.peerInfo):
    libp2p_peers.set(c.peerCount().int64)

  trace "Stored connection",
    conn, direction = $conn.dir, connections = c.conns.len

proc trackConn*(c: ConnManager,
                provider: ConnProvider,
                dir: Direction): Future[Connection] {.async.} =
  var conn: Connection
  try:
    await c.connSemaphore.acquire()
    conn = await provider()

    if isNil(conn):
      raise newException(CatchableError, "Connection cannot be nil")

    conn.dir = dir
    trace "Got connection", conn, dir = $dir

    c.storeConn(conn)
    return conn
  except CatchableError as exc:
    trace "Exception tracking connection", exc = exc.msg

    if not isNil(conn):
      await conn.close()

    c.connSemaphore.release()
    raise exc

proc trackIncomingConn*(c: ConnManager,
                        provider: ConnProvider): Future[Connection] =
  trace "Tracking incoming connection"
  c.trackConn(provider, Direction.In)

proc trackOutgoingConn*(c: ConnManager,
                        provider: ConnProvider): Future[Connection] =
  trace "Tracking outgoing connection"
  c.trackConn(provider, Direction.Out)

proc storeMuxer*(c: ConnManager,
                 muxer: Muxer,
                 handle: Future[void] = nil) =
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
                     peerId: PeerID,
                     dir: Direction): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the provided peer
  ## with the given direction
  ##

  let muxer = c.selectMuxer(peerId, dir)
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getStream*(c: ConnManager, peerId: PeerID): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed peer from any connection
  ##

  let muxer = c.selectMuxer(peerId)
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getStream*(c: ConnManager, conn: Connection): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed connection
  ##

  let muxer = c.selectMuxer(conn)
  if not(isNil(muxer)):
    return await muxer.newStream()

proc dropPeer*(c: ConnManager, peerId: PeerID) {.async.} =
  ## drop connections and cleanup resources for peer
  ##

  trace "Dropping peer", peerId
  # TODO: inflight connections for this
  # peer can still be added after upgrade
  let conns = c.conns.filter((h) =>
    (not isNil(h.conn.peerInfo) and
      h.conn.peerInfo.peerId == peerId))

  for h in conns:
    trace  "Removing connection", conn = h.conn
    delConn(c, h.conn)

  var muxers: seq[MuxerHolder]
  let muxedConns = toSeq(c.muxed.keys).filterIt(
    it.peerInfo.peerId == peerId
  )

  for conn in muxedConns:
    muxers.add c.muxed[conn]
    c.muxed.del(conn)

  for muxer in muxers:
    await closeMuxerHolder(muxer)

  for h in conns:
    await h.conn.close()
    trace "Dropped peer", peerId

  trace "Peer dropped", peerId

proc close*(c: ConnManager) {.async.} =
  ## cleanup resources for the connection
  ## manager
  ##

  trace "Closing ConnManager"
  let conns = c.conns
  c.conns.setLen(0)

  let muxed = c.muxed
  c.muxed.clear()

  for _, muxer in muxed:
    await closeMuxerHolder(muxer)

  for h in conns:
    await h.conn.close()

  trace "Closed ConnManager"

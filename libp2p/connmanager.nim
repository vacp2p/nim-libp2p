## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[options, tables, sequtils, sets]
import chronos, chronicles, metrics
import peerinfo,
       stream/connection,
       muxers/muxer

declareGauge(libp2p_peers, "total connected peers")

const MaxConnectionsPerPeer = 5

type
  TooManyConnections* = object of CatchableError

  MuxerHolder = object
    muxer: Muxer
    handle: Future[void]

  ConnManager* = ref object of RootObj
    # NOTE: don't change to PeerInfo here
    # the reference semantics on the PeerInfo
    # object itself make it succeptible to
    # copies and mangling by unrelated code.
    conns: Table[PeerID, HashSet[Connection]]
    muxed: Table[Connection, MuxerHolder]
    maxConns: int

proc newTooManyConnections(): ref TooManyConnections {.inline.} =
  result = newException(TooManyConnections, "too many connections for peer")

proc init*(C: type ConnManager,
           maxConnsPerPeer: int = MaxConnectionsPerPeer): ConnManager =
  C(maxConns: maxConnsPerPeer,
    conns: initTable[PeerID, HashSet[Connection]](),
    muxed: initTable[Connection, MuxerHolder]())

proc contains*(c: ConnManager, conn: Connection): bool =
  ## checks if a connection is being tracked by the
  ## connection manager
  ##

  if isNil(conn):
    return

  if isNil(conn.peerInfo):
    return

  return conn in c.conns[conn.peerInfo.peerId]

proc contains*(c: ConnManager, peerId: PeerID): bool =
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

  if isNil(conn):
    return

  if isNil(conn.peerInfo):
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
    # do not need to propogate CancelledError.
    debug "Unexpected cancellation in connection manager's cleanup", conn
  except CatchableError as exc:
    debug "Unexpected exception in connection manager's cleanup",
          errMsg = exc.msg, conn

proc selectConn*(c: ConnManager,
                peerId: PeerID,
                dir: Direction): Connection =
  ## Select a connection for the provided peer and direction
  ##
  let conns = toSeq(
    c.conns.getOrDefault(peerId))
    .filterIt( it.dir == dir )

  if conns.len > 0:
    return conns[0]

proc selectConn*(c: ConnManager, peerId: PeerID): Connection =
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

proc storeConn*(c: ConnManager, conn: Connection) =
  ## store a connection
  ##

  if isNil(conn):
    raise newException(CatchableError, "connection cannot be nil")

  if isNil(conn.peerInfo):
    raise newException(CatchableError, "empty peer info")

  let peerId = conn.peerInfo.peerId
  if c.conns.getOrDefault(peerId).len > c.maxConns:
    debug "too many connections", peer = conn,
                                  conns = c.conns.getOrDefault(peerId).len

    raise newTooManyConnections()

  if peerId notin c.conns:
    c.conns[peerId] = initHashSet[Connection]()

  c.conns[peerId].incl(conn)

  # Launch on close listener
  # All the errors are handled inside `onClose()` procedure.
  asyncSpawn c.onClose(conn)
  libp2p_peers.set(c.conns.len.int64)

  trace "Stored connection",
    connections = c.conns.len, conn, direction = $conn.dir

proc storeOutgoing*(c: ConnManager, conn: Connection) =
  conn.dir = Direction.Out
  c.storeConn(conn)

proc storeIncoming*(c: ConnManager, conn: Connection) =
  conn.dir = Direction.In
  c.storeConn(conn)

proc storeMuxer*(c: ConnManager,
                 muxer: Muxer,
                 handle: Future[void] = nil) =
  ## store the connection and muxer
  ##

  if isNil(muxer):
    raise newException(CatchableError, "muxer cannot be nil")

  if isNil(muxer.connection):
    raise newException(CatchableError, "muxer's connection cannot be nil")

  c.muxed[muxer.connection] = MuxerHolder(
    muxer: muxer,
    handle: handle)

  trace "Stored muxer", connections = c.conns.len, muxer

proc getMuxedStream*(c: ConnManager,
                     peerId: PeerID,
                     dir: Direction): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the provided peer
  ## with the given direction
  ##

  let muxer = c.selectMuxer(c.selectConn(peerId, dir))
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getMuxedStream*(c: ConnManager,
                     peerId: PeerID): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed peer from any connection
  ##

  let muxer = c.selectMuxer(c.selectConn(peerId))
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getMuxedStream*(c: ConnManager,
                     conn: Connection): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed connection
  ##

  let muxer = c.selectMuxer(conn)
  if not(isNil(muxer)):
    return await muxer.newStream()

proc dropPeer*(c: ConnManager, peerId: PeerID) {.async.} =
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

proc close*(c: ConnManager) {.async.} =
  ## cleanup resources for the connection
  ## manager
  ##
  let conns = c.conns
  c.conns.clear()

  let muxed = c.muxed
  c.muxed.clear()

  for _, muxer in muxed:
    await closeMuxerHolder(muxer)

  for _, conns2 in conns:
    for conn in conns2:
      await conn.close()

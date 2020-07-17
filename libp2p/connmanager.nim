## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import tables, sequtils, sets
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
    cleanUpLock: Table[PeerInfo, AsyncLock]
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

  if conn.peerInfo.peerId notin c.conns:
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

proc cleanupConn(c: ConnManager, conn: Connection) {.async.} =
  ## clean connection's resources such as muxers and streams
  ##

  if isNil(conn):
    return

  if isNil(conn.peerInfo):
    return

  let peerInfo = conn.peerInfo
  let lock = c.cleanUpLock.mgetOrPut(peerInfo, newAsyncLock())

  try:
    await lock.acquire()
    trace "cleaning up connection for peer", peer = $peerInfo
    if conn in c.muxed:
      let muxerHolder = c.muxed[conn]
      c.muxed.del(conn)

      await muxerHolder.muxer.close()
      if not(isNil(muxerHolder.handle)):
        await muxerHolder.handle

    if peerInfo.peerId in c.conns:
      c.conns[peerInfo.peerId].excl(conn)

      if c.conns[peerInfo.peerId].len == 0:
        c.conns.del(peerInfo.peerId)

    if not(conn.peerInfo.isClosed()):
      conn.peerInfo.close()

  finally:
    await conn.close()
    libp2p_peers.set(c.conns.len.int64)

    if lock.locked():
      lock.release()

    trace "connection cleaned up"

proc onClose(c: ConnManager, conn: Connection) {.async.} =
  ## connection close even handler
  ##
  ## triggers the connections resource cleanup
  ##

  await conn.closeEvent.wait()
  trace "triggering connection cleanup"
  await c.cleanupConn(conn)

proc selectConn*(c: ConnManager,
                peerInfo: PeerInfo,
                dir: Direction): Connection =
  ## Select a connection for the provided peer and direction
  ##

  if isNil(peerInfo):
    return

  let conns = toSeq(
    c.conns.getOrDefault(peerInfo.peerId))
    .filterIt( it.dir == dir )

  if conns.len > 0:
    return conns[0]

proc selectConn*(c: ConnManager, peerInfo: PeerInfo): Connection =
  ## Select a connection for the provided giving priority
  ## to outgoing connections
  ##

  if isNil(peerInfo):
    return

  var conn = c.selectConn(peerInfo, Direction.Out)
  if isNil(conn):
    conn = c.selectConn(peerInfo, Direction.In)

  return conn

proc selectMuxer*(c: ConnManager, conn: Connection): Muxer =
  ## select the muxer for the provided connection
  ##

  if isNil(conn):
    return

  if conn in c.muxed:
    return c.muxed[conn].muxer

proc storeConn*(c: ConnManager, conn: Connection) =
  ## store a connection
  ##

  if isNil(conn):
    raise newException(CatchableError, "connection cannot be nil")

  if isNil(conn.peerInfo):
    raise newException(CatchableError, "empty peer info")

  let peerInfo = conn.peerInfo
  if c.conns.getOrDefault(peerInfo.peerId).len > c.maxConns:
    trace "too many connections", peer = $conn.peerInfo,
                                  conns = c.conns
                                  .getOrDefault(peerInfo.peerId).len

    raise newTooManyConnections()

  if peerInfo.peerId notin c.conns:
    c.conns[peerInfo.peerId] = initHashSet[Connection]()

  c.conns[peerInfo.peerId].incl(conn)

  # launch on close listener
  asyncCheck c.onClose(conn)
  libp2p_peers.set(c.conns.len.int64)

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

  trace "storred connection", connections = c.conns.len

proc getMuxedStream*(c: ConnManager,
                     peerInfo: PeerInfo,
                     dir: Direction): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the provided peer
  ## with the given direction
  ##

  let muxer = c.selectMuxer(c.selectConn(peerInfo, dir))
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getMuxedStream*(c: ConnManager,
                     peerInfo: PeerInfo): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed peer from any connection
  ##

  let muxer = c.selectMuxer(c.selectConn(peerInfo))
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getMuxedStream*(c: ConnManager,
                     conn: Connection): Future[Connection] {.async, gcsafe.} =
  ## get a muxed stream for the passed connection
  ##

  let muxer = c.selectMuxer(conn)
  if not(isNil(muxer)):
    return await muxer.newStream()

proc dropPeer*(c: ConnManager, peerInfo: PeerInfo) {.async.} =
  ## drop connections and cleanup resources for peer
  ##

  for conn in c.conns.getOrDefault(peerInfo.peerId):
    if not(isNil(conn)):
      await c.cleanupConn(conn)

proc close*(c: ConnManager) {.async.} =
  ## cleanup resources for the connection
  ## manager
  ##

  for conns in toSeq(c.conns.values):
    for conn in conns:
      try:
        await c.cleanupConn(conn)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        warn "error cleaning up connections"

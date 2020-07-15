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
import peerinfo, stream/connection, muxers/muxer

declareGauge(libp2p_peers, "total connected peers")

const MaxConnectionsPerPeer = 5

type
  TooManyConnections* = object of CatchableError

  MuxerHolder = object
    muxer: Muxer
    handle: Future[void]

  ConnManager* = ref object of RootObj
    conns: Table[PeerInfo, HashSet[Connection]]
    muxed: Table[Connection, MuxerHolder]
    cleanUpLock: Table[PeerInfo, AsyncLock]
    maxConns: int

proc newTooManyConnections(): ref TooManyConnections {.inline.} =
  result = newException(TooManyConnections, "too many connections for peer")

proc init*(C: type ConnManager,
           maxConnsPerPeer: int = MaxConnectionsPerPeer): ConnManager =
  C(maxConns: maxConnsPerPeer,
    conns: initTable[PeerInfo, HashSet[Connection]](),
    muxed: initTable[Connection, MuxerHolder]())

proc contains*(c: ConnManager, conn: Connection): bool =
  if isNil(conn):
    return

  if isNil(conn.peerInfo):
    return

  if conn.peerInfo notin c.conns:
    return

  return conn in c.conns[conn.peerInfo]

proc contains*(c: ConnManager, muxer: Muxer): bool =
  if isNil(muxer):
    return

  let conn = muxer.connection
  if conn notin c:
    return

  if conn notin c.muxed:
    return

  return muxer == c.muxed[conn].muxer

proc cleanupConn(c: ConnManager, conn: Connection) {.async.} =
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

      if peerInfo in c.conns:
        c.conns[peerInfo].excl(conn)

        if c.conns[peerInfo].len == 0:
          c.conns.del(peerInfo)

      if not(conn.peerInfo.isClosed()):
        conn.peerInfo.close()

    finally:
      await conn.close()
      libp2p_peers.set(c.conns.len.int64)

      if lock.locked():
        lock.release()

proc onClose(c: ConnManager, conn: Connection) {.async.} =
  # connection close event handler
  await conn.closeEvent.wait()
  await c.cleanupConn(conn)

proc selectConn*(c: ConnManager,
                peerInfo: PeerInfo,
                dir: Direction): Connection =
  ## Select a connection for the provided peer and direction
  ##

  if isNil(peerInfo):
    return

  let conns = toSeq(
    c.conns.getOrDefault(peerInfo))
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
  ## select the muxer for the supplied connection
  ##

  if isNil(conn):
    return

  if conn in c.muxed:
    return c.muxed[conn].muxer

proc storeConn*(c: ConnManager, conn: Connection) =
  if isNil(conn):
    raise newException(CatchableError, "connection cannot be nil")

  if isNil(conn.peerInfo):
    raise newException(CatchableError, "empty peer info")

  let peerInfo = conn.peerInfo
  if c.conns.getOrDefault(peerInfo).len > c.maxConns:
    warn "disconnecting peer, too many connections", peer = $conn.peerInfo,
                                                      conns = c.conns
                                                      .getOrDefault(peerInfo).len
    raise newTooManyConnections()

  if peerInfo notin c.conns:
    c.conns[peerInfo] = initHashSet[Connection]()

  c.conns[peerInfo].incl(conn)

  # launch on close listener
  asyncCheck c.onClose(conn)
  libp2p_peers.set(c.conns.len.int64)

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
  # if there is a muxer for the connection
  # use it instead to create a muxed stream

  let muxer = c.selectMuxer(c.selectConn(peerInfo, dir)) # always get the first muxer here
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getMuxedStream*(c: ConnManager,
                     peerInfo: PeerInfo): Future[Connection] {.async, gcsafe.} =
  # if there is a muxer for the connection
  # use it instead to create a muxed stream

  let muxer = c.selectMuxer(c.selectConn(peerInfo)) # always get the first muxer here
  if not(isNil(muxer)):
    return await muxer.newStream()

proc getMuxedStream*(c: ConnManager,
                     conn: Connection): Future[Connection] {.async, gcsafe.} =
  # if there is a muxer for the connection
  # use it instead to create a muxed stream

  let muxer = c.selectMuxer(conn) # always get the first muxer here
  if not(isNil(muxer)):
    return await muxer.newStream()

proc dropConns*(c: ConnManager, peerInfo: PeerInfo) {.async.} =
  for conn in c.conns.getOrDefault(peerInfo):
    if not(isNil(conn)):
      await c.cleanupConn(conn)

proc close*(c: ConnManager) {.async.} =
  for conns in toSeq(c.conns.values):
    for conn in conns:
      try:
        await c.cleanupConn(conn)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        warn "error cleaning up connections"

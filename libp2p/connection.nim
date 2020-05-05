## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import oids
import chronos, chronicles, metrics
import peerinfo,
       errors,
       multiaddress,
       stream/lpstream,
       peerinfo

export lpstream

export lpstream

logScope:
  topic = "Connection"

const
  ConnectionTrackerName* = "libp2p.connection"

type
  Connection* = ref object of LPStream
    peerInfo*: PeerInfo
    stream*: LPStream
    observedAddrs*: Multiaddress
    # notice this is a ugly circular reference collection
    # (we got many actually :-))
    readLoops*: seq[Future[void]]

  ConnectionTracker* = ref object of TrackerBase
    opened*: uint64
    closed*: uint64

proc setupConnectionTracker(): ConnectionTracker {.gcsafe.}

proc getConnectionTracker*(): ConnectionTracker {.gcsafe.} =
  result = cast[ConnectionTracker](getTracker(ConnectionTrackerName))
  if isNil(result):
    result = setupConnectionTracker()

proc dumpTracking(): string {.gcsafe.} =
  var tracker = getConnectionTracker()
  result = "Opened conns: " & $tracker.opened & "\n" &
           "Closed conns: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getConnectionTracker()
  result = (tracker.opened != tracker.closed)

proc setupConnectionTracker(): ConnectionTracker =
  result = new ConnectionTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTracking
  result.isLeaked = leakTransport
  addTracker(ConnectionTrackerName, result)

declareGauge libp2p_open_connection, "open Connection instances"

proc `$`*(conn: Connection): string =
  if not isNil(conn.peerInfo):
    result = $(conn.peerInfo)

proc bindStreamClose(conn: Connection) {.async.} =
  # bind stream's close event to connection's close
  # to ensure correct close propagation
  if not isNil(conn.stream.closeEvent):
    await conn.stream.closeEvent.wait()
    trace "wrapped stream closed, about to close conn",
      closed = conn.isClosed, conn = $conn
    if not conn.isClosed:
      trace "wrapped stream closed, closing conn",
        closed = conn.isClosed, conn = $conn
      await conn.close()

proc init[T: Connection](self: var T, stream: LPStream): T =
  ## create a new Connection for the specified async reader/writer
  new self
  self.stream = stream
  self.closeEvent = newAsyncEvent()
  when chronicles.enabledLogLevel == LogLevel.TRACE:
    self.oid = genOid()
  asyncCheck self.bindStreamClose()
  inc getConnectionTracker().opened
  libp2p_open_connection.inc()

  return self

proc newConnection*(stream: LPStream): Connection =
  ## create a new Connection for the specified async reader/writer
  result.init(stream)

method readExactly*(s: Connection,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] {.gcsafe.} =
  s.stream.readExactly(pbytes, nbytes)

method readOnce*(s: Connection,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.gcsafe.} =
  s.stream.readOnce(pbytes, nbytes)

method write*(s: Connection,
              msg: seq[byte]):
              Future[void] {.gcsafe.} =
  s.stream.write(msg)

method closed*(s: Connection): bool =
  if isNil(s.stream):
    return true

  result = s.stream.closed

method close*(s: Connection) {.async, gcsafe.} =
  trace "about to close connection", closed = s.closed, conn = $s

  if not s.isClosed:
    s.isClosed = true
    inc getConnectionTracker().closed

    if not isNil(s.stream) and not s.stream.closed:
      trace "closing child stream", closed = s.closed, conn = $s
      try:
        await s.stream.close()
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        debug "Error while closing child stream", err = exc.msg

    s.closeEvent.fire()

    trace "waiting readloops", count=s.readLoops.len, conn = $s
    let loopFuts = await allFinished(s.readLoops)
    checkFutures(loopFuts)
    s.readLoops = @[]

    trace "connection closed", closed = s.closed, conn = $s
    libp2p_open_connection.dec()

method getObservedAddrs*(c: Connection): Future[MultiAddress] {.base, async, gcsafe.} =
  ## get resolved multiaddresses for the connection
  result = c.observedAddrs

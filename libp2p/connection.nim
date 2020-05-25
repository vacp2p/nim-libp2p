## Nim-LibP2P
## Copyright (c) 2019 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, chronicles, metrics
import peerinfo,
       errors,
       multiaddress,
       stream/lpstream,
       peerinfo

when chronicles.enabledLogLevel == LogLevel.TRACE:
  import oids

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

proc init[T: Connection](self: var T, stream: LPStream): T =
  ## create a new Connection for the specified async reader/writer
  new self
  self.stream = stream
  self.initStream()
  return self

proc newConnection*(stream: LPStream): Connection =
  ## create a new Connection for the specified async reader/writer
  result.init(stream)

method initStream*(s: Connection) =
  procCall LPStream(s).initStream()
  trace "created connection", oid = s.oid
  inc getConnectionTracker().opened
  libp2p_open_connection.inc()

method readExactly*(s: Connection,
                    pbytes: pointer,
                    nbytes: int):
                    Future[void] {.async, gcsafe.} =
  await s.stream.readExactly(pbytes, nbytes)

method readOnce*(s: Connection,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async, gcsafe.} =
  result = await s.stream.readOnce(pbytes, nbytes)

method write*(s: Connection,
              msg: seq[byte]):
              Future[void] {.async, gcsafe.} =
  await s.stream.write(msg)

method atEof*(s: Connection): bool {.inline.} =
  if isNil(s.stream):
    return true

  s.stream.atEof

method closed*(s: Connection): bool =
  if isNil(s.stream):
    return true

  result = s.stream.closed

method close*(s: Connection) {.async, gcsafe.} =
  try:
    if not s.isClosed:
      s.isClosed = true

      trace "about to close connection", closed = s.closed,
                                        conn = $s,
                                        oid = s.oid


      if not isNil(s.stream) and not s.stream.closed:
        trace "closing child stream", closed = s.closed,
                                      conn = $s,
                                      oid = s.stream.oid
        await s.stream.close()
        # s.stream = nil

      s.closeEvent.fire()
      trace "connection closed", closed = s.closed,
                                 conn = $s,
                                 oid = s.oid

      inc getConnectionTracker().closed
      libp2p_open_connection.dec()
  except CatchableError as exc:
    trace "exception closing connections", exc = exc.msg

method getObservedAddrs*(c: Connection): Future[MultiAddress] {.base, async, gcsafe.} =
  ## get resolved multiaddresses for the connection
  result = c.observedAddrs

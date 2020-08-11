## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import hashes, oids
import chronicles, chronos, metrics
import lpstream,
       ../multiaddress,
       ../peerinfo

export lpstream

logScope:
  topics = "connection"

const
  ConnectionTrackerName* = "libp2p.connection"
  DefaultConnectionTimeout* = 5.minutes

type
  TimeoutHandler* = proc(): Future[void] {.gcsafe.}

  Direction* {.pure.} = enum
    None, In, Out

  Connection* = ref object of LPStream
    activity*: bool                 # reset every time data is sent or received
    timeout*: Duration              # channel timeout if no activity
    timerTaskFut: Future[void]      # the current timer instanse
    timeoutHandler*: TimeoutHandler # timeout handler
    peerInfo*: PeerInfo
    observedAddr*: Multiaddress
    dir*: Direction

  ConnectionTracker* = ref object of TrackerBase
    opened*: uint64
    closed*: uint64

proc setupConnectionTracker(): ConnectionTracker {.gcsafe.}
proc timeoutMonitor(s: Connection) {.async, gcsafe.}

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

method initStream*(s: Connection) =
  if s.objName.len == 0:
    s.objName = "Connection"

  procCall LPStream(s).initStream()
  s.closeEvent = newAsyncEvent()

  if isNil(s.timeoutHandler):
    s.timeoutHandler = proc() {.async.} =
      await s.close()

  trace "timeout set at", timeout = $s.timeout.millis
  doAssert(isNil(s.timerTaskFut))
  # doAssert(s.timeout > 0.millis)
  if s.timeout > 0.millis:
    s.timerTaskFut = s.timeoutMonitor()

  inc getConnectionTracker().opened

method close*(s: Connection) {.async.} =
  ## cleanup timers
  if not isNil(s.timerTaskFut) and not s.timerTaskFut.finished:
    s.timerTaskFut.cancel()

  if not s.isClosed:
    await procCall LPStream(s).close()
    inc getConnectionTracker().closed

proc `$`*(conn: Connection): string =
  if not isNil(conn.peerInfo):
    result = conn.peerInfo.id

func hash*(p: Connection): Hash =
  cast[pointer](p).hash

proc timeoutMonitor(s: Connection) {.async, gcsafe.} =
  ## monitor the channel for innactivity
  ##
  ## if the timeout was hit, it means that
  ## neither incoming nor outgoing activity
  ## has been detected and the channel will
  ## be reset
  ##

  logScope:
    oid = $s.oid

  try:
    while true:
      await sleepAsync(s.timeout)

      if s.closed or s.atEof:
        return

      if s.activity:
        s.activity = false
        continue

      break

    # reset channel on innactivity timeout
    trace "Connection timed out"
    if not(isNil(s.timeoutHandler)):
      await s.timeoutHandler()

  except CancelledError as exc:
    raise exc
  except CatchableError as exc:
    trace "exception in timeout", exc = exc.msg

proc init*(C: type Connection,
           peerInfo: PeerInfo,
           dir: Direction,
           timeout: Duration = DefaultConnectionTimeout,
           timeoutHandler: TimeoutHandler = nil): Connection =
  result = C(peerInfo: peerInfo,
             dir: dir,
             timeout: timeout,
             timeoutHandler: timeoutHandler)

  result.initStream()

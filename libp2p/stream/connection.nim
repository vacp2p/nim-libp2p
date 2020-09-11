## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import std/[hashes, oids, strformat]
import chronicles, chronos, metrics
import lpstream,
       ../multiaddress,
       ../peerinfo

export lpstream, peerinfo

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
    timerTaskFut: Future[void]      # the current timer instance
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

func shortLog*(conn: Connection): string =
  if conn.isNil: "Connection(nil)"
  elif conn.peerInfo.isNil: $conn.oid
  else: &"{shortLog(conn.peerInfo.peerId)}:{conn.oid}"
chronicles.formatIt(Connection): shortLog(it)

method initStream*(s: Connection) =
  if s.objName.len == 0:
    s.objName = "Connection"

  procCall LPStream(s).initStream()

  doAssert(isNil(s.timerTaskFut))

  if s.timeout > 0.millis:
    trace "Monitoring for timeout", s, timeout = s.timeout

    s.timerTaskFut = s.timeoutMonitor()
    if isNil(s.timeoutHandler):
      s.timeoutHandler = proc(): Future[void] = s.close()

  inc getConnectionTracker().opened

method close*(s: Connection) {.async.} =
  ## cleanup timers
  if not isNil(s.timerTaskFut) and not s.timerTaskFut.finished:
    s.timerTaskFut.cancel()

  if not s.isClosed:
    await procCall LPStream(s).close()
    inc getConnectionTracker().closed

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
    trace "Connection timed out", s
    if not(isNil(s.timeoutHandler)):
      await s.timeoutHandler()

  except CancelledError as exc:
    raise exc
  except CatchableError as exc: # Shouldn't happen
    warn "exception in timeout", s, exc = exc.msg
  finally:
    s.timerTaskFut = nil

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

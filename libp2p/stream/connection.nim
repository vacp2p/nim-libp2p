# Nim-LibP2P
# Copyright (c) 2023-2024 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}

import std/[hashes, oids, strformat]
import results
import chronicles, chronos, metrics
import lpstream, ../multiaddress, ../peerinfo, ../errors

export lpstream, peerinfo, errors, results

logScope:
  topics = "libp2p connection"

const
  ConnectionTrackerName* = "Connection"
  DefaultConnectionTimeout* = 5.minutes

type
  TimeoutHandler* = proc(): Future[void] {.async: (raises: []).}

  Connection* = ref object of LPStream
    activity*: bool # reset every time data is sent or received
    timeout*: Duration # channel timeout if no activity
    timerTaskFut: Future[void].Raising([]) # the current timer instance
    timeoutHandler*: TimeoutHandler # timeout handler
    peerId*: PeerId
    observedAddr*: Opt[MultiAddress]
    protocol*: string # protocol used by the connection, used as metrics tag
    transportDir*: Direction # underlying transport (usually socket) direction
    when defined(libp2p_agents_metrics):
      shortAgent*: string

proc timeoutMonitor(s: Connection) {.async: (raises: []).}

method shortLog*(conn: Connection): string {.gcsafe, base, raises: [].} =
  if conn == nil:
    "Connection(nil)"
  else:
    &"{shortLog(conn.peerId)}:{conn.oid}:{conn.protocol}"

chronicles.formatIt(Connection):
  shortLog(it)

method initStream*(s: Connection) =
  if s.objName.len == 0:
    s.objName = ConnectionTrackerName

  procCall LPStream(s).initStream()

  doAssert(s.timerTaskFut == nil)

  if s.timeout > 0.millis:
    trace "Monitoring for timeout", s, timeout = s.timeout

    s.timerTaskFut = s.timeoutMonitor()
    if s.timeoutHandler == nil:
      s.timeoutHandler = proc(): Future[void] {.async: (raises: [], raw: true).} =
        trace "Idle timeout expired, closing connection", s
        s.close()

method closeImpl*(s: Connection): Future[void] {.async: (raises: []).} =
  # Cleanup timeout timer
  trace "Closing connection", s

  if s.timerTaskFut != nil and not s.timerTaskFut.finished:
    # Don't `cancelAndWait` here to avoid risking deadlock in this scenario:
    # - `pollActivity` is waiting for `s.timeoutHandler` to complete.
    # - `s.timeoutHandler` may have triggered `closeImpl` and we are now here.
    # In this situation, we have to return for `s.timerTaskFut` to complete.
    s.timerTaskFut.cancelSoon()
    s.timerTaskFut = nil

  trace "Closed connection", s

  procCall LPStream(s).closeImpl()

func hash*(p: Connection): Hash =
  cast[pointer](p).hash

proc pollActivity(s: Connection): Future[bool] {.async: (raises: []).} =
  if s.closed and s.atEof:
    return false # Done, no more monitoring

  if s.activity:
    s.activity = false
    return true

  # Inactivity timeout happened, call timeout monitor

  trace "Connection timed out", s
  if s.timeoutHandler != nil:
    trace "Calling timeout handler", s
    await s.timeoutHandler()

  return false

proc timeoutMonitor(s: Connection) {.async: (raises: []).} =
  ## monitor the channel for inactivity
  ##
  ## if the timeout was hit, it means that
  ## neither incoming nor outgoing activity
  ## has been detected and the channel will
  ## be reset
  ##

  while true:
    try: # Sleep at least once!
      await sleepAsync(s.timeout)
    except CancelledError:
      return

    if not await s.pollActivity():
      return

method getWrapped*(s: Connection): Connection {.base.} =
  raiseAssert("[Connection.getWrapped] abstract method not implemented!")

when defined(libp2p_agents_metrics):
  proc setShortAgent*(s: Connection, shortAgent: string) =
    var conn = s
    while conn != nil:
      conn.shortAgent = shortAgent
      conn = conn.getWrapped()

proc new*(
    C: type Connection,
    peerId: PeerId,
    dir: Direction,
    observedAddr: Opt[MultiAddress],
    timeout: Duration = DefaultConnectionTimeout,
    timeoutHandler: TimeoutHandler = nil,
): Connection =
  result = C(
    peerId: peerId,
    dir: dir,
    timeout: timeout,
    timeoutHandler: timeoutHandler,
    observedAddr: observedAddr,
  )

  result.initStream()

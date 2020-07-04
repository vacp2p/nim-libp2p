## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos, metrics
import lpstream,
       ../multiaddress,
       ../peerinfo

export lpstream

const
  ConnectionTrackerName* = "libp2p.connection"

type
  Connection* = ref object of LPStream
    peerInfo*: PeerInfo
    observedAddr*: Multiaddress

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

proc init*[T: Connection](self: var T, peerInfo: PeerInfo): T =
  new self
  self.initStream()

method initStream*(s: Connection) =
  if s.objName.len == 0:
    s.objName = "Connection"

  procCall LPStream(s).initStream()
  s.closeEvent = newAsyncEvent()
  inc getConnectionTracker().opened

method close*(s: Connection) {.async.} =
  await procCall LPStream(s).close()
  inc getConnectionTracker().closed

proc `$`*(conn: Connection): string =
  if not isNil(conn.peerInfo):
    result = conn.peerInfo.id

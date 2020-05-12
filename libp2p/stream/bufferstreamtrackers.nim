## Nim-LibP2P
## Copyright (c) 2020 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import chronos

#TODO: unify with connection trackers

const
  BufferStreamTrackerName* = "libp2p.bufferstream"

type
  BufferStreamTracker* = ref object of TrackerBase
    opened*: uint64
    closed*: uint64

proc setupBufferStreamTracker(): BufferStreamTracker {.gcsafe.}

proc getBufferStreamTracker*(): BufferStreamTracker {.gcsafe.} =
  result = cast[BufferStreamTracker](getTracker(BufferStreamTrackerName))
  if isNil(result):
    result = setupBufferStreamTracker()

proc dumpTracking(): string {.gcsafe.} =
  var tracker = getBufferStreamTracker()
  result = "Opened buffers: " & $tracker.opened & "\n" &
           "Closed buffers: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getBufferStreamTracker()
  result = (tracker.opened != tracker.closed)

proc setupBufferStreamTracker(): BufferStreamTracker =
  result = new BufferStreamTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTracking
  result.isLeaked = leakTransport
  addTracker(BufferStreamTrackerName, result)

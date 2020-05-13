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
  ChronosStreamTrackerName* = "libp2p.bufferstream"

type
  ChronosStreamTracker* = ref object of TrackerBase
    opened*: uint64
    closed*: uint64

proc setupChronosStreamTracker(): ChronosStreamTracker {.gcsafe.}

proc getChronosStreamTracker*(): ChronosStreamTracker {.gcsafe.} =
  result = cast[ChronosStreamTracker](getTracker(ChronosStreamTrackerName))
  if isNil(result):
    result = setupChronosStreamTracker()

proc dumpTracking(): string {.gcsafe.} =
  var tracker = getChronosStreamTracker()
  result = "Opened buffers: " & $tracker.opened & "\n" &
           "Closed buffers: " & $tracker.closed

proc leakTransport(): bool {.gcsafe.} =
  var tracker = getChronosStreamTracker()
  result = (tracker.opened != tracker.closed)

proc setupChronosStreamTracker(): ChronosStreamTracker =
  result = new ChronosStreamTracker
  result.opened = 0
  result.closed = 0
  result.dump = dumpTracking
  result.isLeaked = leakTransport
  addTracker(ChronosStreamTrackerName, result)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import chronos, unittest2

from ../../libp2p/stream/connection import LPStreamTrackerName, ConnectionTrackerName
from ../../libp2p/stream/bufferstream import BufferStreamTrackerName
from ../../libp2p/stream/chronosstream import ChronosStreamTrackerName
from ../../libp2p/transports/tcptransport import
  SecureConnTrackerName, TcpTransportTrackerName
from ../../libp2p/muxers/mplex/lpchannel import LPChannelTrackerName

const
  StreamTransportTrackerName = "stream.transport"
  StreamServerTrackerName = "stream.server"
  DgramTransportTrackerName = "datagram.transport"

const AllTrackerNames* = [
  LPStreamTrackerName, ConnectionTrackerName, LPChannelTrackerName,
  SecureConnTrackerName, BufferStreamTrackerName, TcpTransportTrackerName,
  StreamTransportTrackerName, StreamServerTrackerName, DgramTransportTrackerName,
  ChronosStreamTrackerName,
]

proc reconcileTracker(name: string, opened: int, closed: int) =
  if opened >= closed:
    for _ in 0 ..< opened - closed:
      untrackCounter(name)
  else:
    for _ in 0 ..< closed - opened:
      trackCounter(name)

template checkTracker*(name: string) =
  if isCounterLeaked(name):
    let tracker = getTrackerCounter(name)
    let opened = int(tracker.opened)
    let closed = int(tracker.closed)

    checkpoint "\t" & name & ": opened " & $opened & ", closed " & $closed & " (delta " &
      $(opened - closed) & ")"
    fail()

    # Reconcile the counter so the leak does not cascade into following tests.
    reconcileTracker(name, opened, closed)

template checkTrackers*() =
  for name in AllTrackerNames:
    checkTracker(name)
  # Also test the GC is not fooling with us
  try:
    GC_fullCollect()
  except Defect as exc:
    raise exc # Reraise to maintain call stack
  except Exception:
    raiseAssert "Unexpected exception during GC collection"

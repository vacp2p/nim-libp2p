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

template checkTracker*(name: string) =
  if isCounterLeaked(name):
    let
      tracker = getTrackerCounter(name)
      trackerDescription =
        "Opened " & name & ": " & $tracker.opened & "\n" & "Closed " & name & ": " &
        $tracker.closed
    checkpoint trackerDescription
    fail()

template checkTrackers*() =
  for name in AllTrackerNames:
    checkTracker(name)
  # Also test the GC is not fooling with us
  when defined(nimHasWarnBareExcept):
    {.push warning[BareExcept]: off.}
  try:
    GC_fullCollect()
  except Defect as exc:
    raise exc # Reraise to maintain call stack
  except Exception:
    raiseAssert "Unexpected exception during GC collection"
  when defined(nimHasWarnBareExcept):
    {.pop.}
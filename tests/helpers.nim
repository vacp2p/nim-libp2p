import chronos

import ../libp2p/transports/tcptransport
import ../libp2p/stream/bufferstream
import ../libp2p/stream/lpstream

const
  StreamTransportTrackerName = "stream.transport"
  StreamServerTrackerName = "stream.server"

  trackerNames = [
    # ConnectionTrackerName,
    BufferStreamTrackerName,
    TcpTransportTrackerName,
    StreamTransportTrackerName,
    StreamServerTrackerName
  ]

iterator testTrackers*(extras: openArray[string] = []): TrackerBase =
  for name in trackerNames:
    let t = getTracker(name)
    if not isNil(t): yield t
  for name in extras:
    let t = getTracker(name)
    if not isNil(t): yield t

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
import chronos, bearssl

import ../libp2p/transports/tcptransport
import ../libp2p/stream/bufferstream
import ../libp2p/crypto/crypto
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

type RngWrap = object
  rng: ref BrHmacDrbgContext

var rngVar: RngWrap

proc getRng(): ref BrHmacDrbgContext =
  # TODO if `rngVar` is a threadvar like it should be, there are random and
  #      spurious compile failures on mac - this is not gcsafe but for the
  #      purpose of the tests, it's ok as long as we only use a single thread
  {.gcsafe.}:
    if rngVar.rng.isNil:
      rngVar.rng = newRng()
    rngVar.rng

template rng*(): ref BrHmacDrbgContext =
  getRng()

type
  WriteHandler* = proc(data: seq[byte]): Future[void] {.gcsafe.}
  TestBufferStream* = ref object of BufferStream
    writeHandler*: WriteHandler

method write*(s: TestBufferStream, msg: seq[byte]): Future[void] =
  s.writeHandler(msg)

proc newBufferStream*(writeHandler: WriteHandler): TestBufferStream =
  new result
  result.writeHandler = writeHandler
  result.initBufferStream()

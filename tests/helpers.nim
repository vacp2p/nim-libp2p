{.push raises: [].}

import chronos
import algorithm

import ../libp2p/transports/tcptransport
import ../libp2p/stream/bufferstream
import ../libp2p/crypto/crypto
import ../libp2p/stream/lpstream
import ../libp2p/stream/chronosstream
import ../libp2p/muxers/mplex/lpchannel
import ../libp2p/protocols/secure/secure
import ../libp2p/switch
import ../libp2p/nameresolving/[nameresolver, mockresolver]

import ./asyncunit
export asyncunit, mockresolver

const
  StreamTransportTrackerName = "stream.transport"
  StreamServerTrackerName = "stream.server"
  DgramTransportTrackerName = "datagram.transport"

  trackerNames = [
    LPStreamTrackerName,
    ConnectionTrackerName,
    LPChannelTrackerName,
    SecureConnTrackerName,
    BufferStreamTrackerName,
    TcpTransportTrackerName,
    StreamTransportTrackerName,
    StreamServerTrackerName,
    DgramTransportTrackerName,
    ChronosStreamTrackerName
  ]

iterator testTrackers*(extras: openArray[string] = []): TrackerBase =
  for name in trackerNames:
    let t = getTracker(name)
    if not isNil(t): yield t
  for name in extras:
    let t = getTracker(name)
    if not isNil(t): yield t

template checkTracker*(name: string) =
  var tracker = getTracker(name)
  if tracker.isLeaked():
    checkpoint tracker.dump()
    fail()

template checkTrackers*() =
  for tracker in testTrackers():
    if tracker.isLeaked():
      checkpoint tracker.dump()
      fail()
  # Also test the GC is not fooling with us
  when defined(nimHasWarnBareExcept):
    {.push warning[BareExcept]:off.}
  try:
    GC_fullCollect()
  except:
    discard
  when defined(nimHasWarnBareExcept):
    {.pop.}

type RngWrap = object
  rng: ref HmacDrbgContext

var rngVar: RngWrap

proc getRng(): ref HmacDrbgContext =
  # TODO if `rngVar` is a threadvar like it should be, there are random and
  #      spurious compile failures on mac - this is not gcsafe but for the
  #      purpose of the tests, it's ok as long as we only use a single thread
  {.gcsafe.}:
    if rngVar.rng.isNil:
      rngVar.rng = newRng()
    rngVar.rng

template rng*(): ref HmacDrbgContext =
  getRng()

type
  WriteHandler* = proc(data: seq[byte]): Future[void] {.gcsafe, raises: [].}
  TestBufferStream* = ref object of BufferStream
    writeHandler*: WriteHandler

method write*(s: TestBufferStream, msg: seq[byte]): Future[void] =
  s.writeHandler(msg)

method getWrapped*(s: TestBufferStream): Connection = nil

proc new*(T: typedesc[TestBufferStream], writeHandler: WriteHandler): T =
  let testBufferStream = T(writeHandler: writeHandler)
  testBufferStream.initStream()
  testBufferStream

proc bridgedConnections*: (Connection, Connection) =
  let
    connA = TestBufferStream()
    connB = TestBufferStream()
  connA.dir = Direction.Out
  connB.dir = Direction.In
  connA.initStream()
  connB.initStream()
  connA.writeHandler = proc(data: seq[byte]) {.async.} =
    await connB.pushData(data)

  connB.writeHandler = proc(data: seq[byte]) {.async.} =
    await connA.pushData(data)
  return (connA, connB)


proc checkExpiringInternal(cond: proc(): bool {.raises: [], gcsafe.} ): Future[bool] {.async.} =
  let start = Moment.now()
  while true:
    if Moment.now() > (start + chronos.seconds(5)):
      return false
    elif cond():
      return true
    else:
      await sleepAsync(1.millis)

template checkExpiring*(code: untyped): untyped =
  check await checkExpiringInternal(proc(): bool = code)

proc unorderedCompare*[T](a, b: seq[T]): bool =
  if a == b:
    return true
  if a.len != b.len:
    return false

  var aSorted = a
  var bSorted = b
  aSorted.sort()
  bSorted.sort()

  if aSorted == bSorted:
    return true

  return false

proc default*(T: typedesc[MockResolver]): T =
  let resolver = MockResolver.new()
  resolver.ipResponses[("localhost", false)] = @["127.0.0.1"]
  resolver.ipResponses[("localhost", true)] = @["::1"]
  resolver

proc setDNSAddr*(switch: Switch) {.async.} =
  proc addressMapper(listenAddrs: seq[MultiAddress]): Future[seq[MultiAddress]] {.async.} =
      return @[MultiAddress.init("/dns4/localhost/").tryGet() & listenAddrs[0][1].tryGet()]
  switch.peerInfo.addressMappers.add(addressMapper)
  await switch.peerInfo.update()

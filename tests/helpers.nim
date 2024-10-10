{.push raises: [].}

import chronos
import macros
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

import errorhelpers
import utils/async_tests

export async_tests, errorhelpers, mockresolver

const
  StreamTransportTrackerName = "stream.transport"
  StreamServerTrackerName = "stream.server"
  DgramTransportTrackerName = "datagram.transport"

  trackerNames = [
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
  for name in trackerNames:
    checkTracker(name)
  # Also test the GC is not fooling with us
  when defined(nimHasWarnBareExcept):
    {.push warning[BareExcept]: off.}
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
  WriteHandler* = proc(data: seq[byte]): Future[void] {.
    async: (raises: [CancelledError, LPStreamError])
  .}

  TestBufferStream* = ref object of BufferStream
    writeHandler*: WriteHandler

method write*(
    s: TestBufferStream, msg: seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  s.writeHandler(msg)

method getWrapped*(s: TestBufferStream): Connection =
  nil

proc new*(T: typedesc[TestBufferStream], writeHandler: WriteHandler): T =
  let testBufferStream = T(writeHandler: writeHandler)
  testBufferStream.initStream()
  testBufferStream

proc bridgedConnections*(): (Connection, Connection) =
  let
    connA = TestBufferStream()
    connB = TestBufferStream()
  connA.dir = Direction.Out
  connB.dir = Direction.In
  connA.initStream()
  connB.initStream()
  connA.writeHandler = proc(
      data: seq[byte]
  ) {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
    connB.pushData(data)

  connB.writeHandler = proc(
      data: seq[byte]
  ) {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
    connA.pushData(data)
  return (connA, connB)

macro checkUntilCustomTimeout*(timeout: Duration, code: untyped): untyped =
  ## Periodically checks a given condition until it is true or a timeout occurs.
  ##
  ## `code`: untyped - A condition expression that should eventually evaluate to true.
  ## `timeout`: Duration - The maximum duration to wait for the condition to be true.
  ##
  ## Examples:
  ##   ```nim
  ##   # Example 1:
  ##   asyncTest "checkUntilCustomTimeout should pass if the condition is true":
  ##     let a = 2
  ##     let b = 2
  ##     checkUntilCustomTimeout(2.seconds):
  ##       a == b
  ##
  ##   # Example 2: Multiple conditions
  ##   asyncTest "checkUntilCustomTimeout should pass if the conditions are true":
  ##     let a = 2
  ##     let b = 2
  ##     checkUntilCustomTimeout(5.seconds)::
  ##       a == b
  ##       a == 2
  ##       b == 1
  ##   ```
  # Helper proc to recursively build a combined boolean expression
  proc buildAndExpr(n: NimNode): NimNode =
    if n.kind == nnkStmtList and n.len > 0:
      var combinedExpr = n[0] # Start with the first expression
      for i in 1 ..< n.len:
        # Combine the current expression with the next using 'and'
        combinedExpr = newCall("and", combinedExpr, n[i])
      return combinedExpr
    else:
      return n

  # Build the combined expression
  let combinedBoolExpr = buildAndExpr(code)

  result = quote:
    proc checkExpiringInternal(): Future[void] {.gensym, async.} =
      let start = Moment.now()
      while true:
        if Moment.now() > (start + `timeout`):
          checkpoint(
            "[TIMEOUT] Timeout was reached and the conditions were not true. Check if the code is working as " &
              "expected or consider increasing the timeout param."
          )
          check `code`
          return
        else:
          if `combinedBoolExpr`:
            return
          else:
            await sleepAsync(100.millis)

    await checkExpiringInternal()

macro checkUntilTimeout*(code: untyped): untyped =
  ## Same as `checkUntilCustomTimeout` but with a default timeout of 10 seconds.
  ##
  ## Examples:
  ##   ```nim
  ##   # Example 1:
  ##   asyncTest "checkUntilTimeout should pass if the condition is true":
  ##     let a = 2
  ##     let b = 2
  ##     checkUntilTimeout:
  ##       a == b
  ##
  ##   # Example 2: Multiple conditions
  ##   asyncTest "checkUntilTimeout should pass if the conditions are true":
  ##     let a = 2
  ##     let b = 2
  ##     checkUntilTimeout:
  ##       a == b
  ##       a == 2
  ##       b == 1
  ##   ```
  result = quote:
    checkUntilCustomTimeout(10.seconds, `code`)

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

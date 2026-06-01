# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, strformat, stew/byteutils
import
  ../../libp2p/[
    multistream,
    stream/bufferstream,
    stream/connection,
    multiaddress,
    transports/transport,
    transports/tcptransport,
    protocols/protocol,
    upgrademngrs/upgrade,
    utils/future,
  ]
import ../tools/[unittest, sync]

{.push raises: [].}

## Mock stream for select test
type TestSelectStream = ref object of Connection
  step*: int

method readOnce*(
    s: TestSelectStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  let fut = newFuture[int]()
  case s.step
  of 1:
    var buf = newSeq[byte](1)
    buf[0] = 19
    copyMem(pbytes, addr buf[0], buf.len())
    s.step = 2
    fut.complete(buf.len)
  of 2:
    var buf = "/multistream/1.0.0\n"
    copyMem(pbytes, addr buf[0], buf.len())
    s.step = 3
    fut.complete(buf.len)
  of 3:
    var buf = newSeq[byte](1)
    buf[0] = 18
    copyMem(pbytes, addr buf[0], buf.len())
    s.step = 4
    fut.complete(buf.len)
  of 4:
    var buf = "/test/proto/1.0.0\n"
    copyMem(pbytes, addr buf[0], buf.len())
    fut.complete(buf.len)
  else:
    copyMem(pbytes, cstring("\0x3na\n"), "\0x3na\n".len())

    fut.complete("\0x3na\n".len())
  fut

method write*(
    s: TestSelectStream, msg: sink seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  newFutureCompleted[void]()

method close(s: TestSelectStream) {.async: (raises: [], raw: true).} =
  s.isClosed = true
  s.isEof = true
  newFutureCompleted[void]()

proc newTestSelectStream(): TestSelectStream =
  TestSelectStream(step: 1)

## Mock stream for handles `ls` test
type
  LsHandler = proc(procs: seq[byte]): Future[void] {.
    async: (raises: [CancelledError, LPStreamError])
  .}

  TestLsStream = ref object of Connection
    step*: int
    ls*: LsHandler

method readOnce*(
    s: TestLsStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  let fut = newFuture[int]()
  case s.step
  of 1:
    var buf = newSeq[byte](1)
    buf[0] = 19
    copyMem(pbytes, addr buf[0], buf.len())
    s.step = 2
    fut.complete(buf.len())
  of 2:
    var buf = "/multistream/1.0.0\n"
    copyMem(pbytes, addr buf[0], buf.len())
    s.step = 3
    fut.complete(buf.len())
  of 3:
    var buf = newSeq[byte](1)
    buf[0] = 3
    copyMem(pbytes, addr buf[0], buf.len())
    s.step = 4
    fut.complete(buf.len())
  of 4:
    var buf = "ls\n"
    copyMem(pbytes, addr buf[0], buf.len())
    fut.complete(buf.len())
  else:
    var buf = "na\n"
    copyMem(pbytes, addr buf[0], buf.len())
    fut.complete(buf.len())
  fut

method write*(
    s: TestLsStream, msg: sink seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  if s.step == 4:
    return s.ls(msg)
  newFutureCompleted[void]()

method close(s: TestLsStream): Future[void] {.async: (raises: [], raw: true).} =
  s.isClosed = true
  s.isEof = true
  newFutureCompleted[void]()

proc newTestLsStream(ls: LsHandler): TestLsStream {.gcsafe.} =
  TestLsStream(ls: ls, step: 1)

## Mock stream for handles `na` test
type
  NaHandler = proc(procs: string): Future[void] {.
    async: (raises: [CancelledError, LPStreamError])
  .}

  TestNaStream = ref object of Connection
    step*: int
    na*: NaHandler

method readOnce*(
    s: TestNaStream, pbytes: pointer, nbytes: int
): Future[int] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  let fut = newFuture[int]()
  case s.step
  of 1:
    var buf = newSeq[byte](1)
    buf[0] = 19
    copyMem(pbytes, addr buf[0], buf.len())
    s.step = 2
    fut.complete(buf.len())
  of 2:
    var buf = "/multistream/1.0.0\n"
    copyMem(pbytes, addr buf[0], buf.len())
    s.step = 3
    fut.complete(buf.len())
  of 3:
    var buf = newSeq[byte](1)
    buf[0] = 18
    copyMem(pbytes, addr buf[0], buf.len())
    s.step = 4
    fut.complete(buf.len())
  of 4:
    var buf = "/test/proto/1.0.0\n"
    copyMem(pbytes, addr buf[0], buf.len())
    fut.complete(buf.len())
  else:
    copyMem(pbytes, cstring("\0x3na\n"), "\0x3na\n".len())

    fut.complete("\0x3na\n".len())
  fut

method write*(
    s: TestNaStream, msg: sink seq[byte]
): Future[void] {.async: (raises: [CancelledError, LPStreamError], raw: true).} =
  if s.step == 4:
    return s.na(string.fromBytes(msg))
  newFutureCompleted[void]()

method close(s: TestNaStream): Future[void] {.async: (raises: [], raw: true).} =
  s.isClosed = true
  s.isEof = true
  newFutureCompleted[void]()

proc newTestNaStream(na: NaHandler): TestNaStream =
  TestNaStream(na: na, step: 1)

proc noReachHandler(
    stream: Stream, proto: string
): Future[void] {.async: (raises: [CancelledError]).} =
  raiseAssert "must not be reached"

suite "Multistream select":
  teardown:
    checkTrackers()

  asyncTest "test select custom proto":
    let ms = MultistreamSelect.new()
    let stream = newTestSelectStream()
    check (await ms.select(stream, @["/test/proto/1.0.0"])) == "/test/proto/1.0.0"
    await stream.close()

  asyncTest "test handle custom proto":
    let ms = MultistreamSelect.new()
    let stream = newTestSelectStream()

    var protocol: LPProtocol = new LPProtocol
    proc testHandler(
        stream: Stream, proto: string
    ): Future[void] {.async: (raises: [CancelledError]).} =
      check proto == "/test/proto/1.0.0"
      await stream.close()

    protocol.codec = "/test/proto/1.0.0"
    protocol.handler = testHandler
    ms.addHandler("/test/proto/1.0.0", protocol)
    await ms.handle(stream)

  asyncTest "test handle invokes only first matching handler":
    let ms = MultistreamSelect.new()
    let stream = newTestSelectStream()

    var firstCalls = 0
    var secondCalls = 0

    var firstProtocol: LPProtocol = new LPProtocol
    proc firstHandler(
        stream: Stream, proto: string
    ): Future[void] {.async: (raises: [CancelledError]).} =
      firstCalls += 1
      check proto == "/test/proto/1.0.0"
      await stream.close()

    var secondProtocol: LPProtocol = new LPProtocol
    proc secondHandler(
        stream: Stream, proto: string
    ): Future[void] {.async: (raises: [CancelledError]).} =
      secondCalls += 1
      check proto == "/test/proto/1.0.0"
      await stream.close()

    firstProtocol.codec = "/test/proto/1.0.0"
    firstProtocol.handler = firstHandler
    secondProtocol.codec = "/test/proto/1.0.0"
    secondProtocol.handler = secondHandler
    ms.addHandler("/test/proto/1.0.0", firstProtocol)
    ms.addHandler("/test/proto/1.0.0", secondProtocol)
    await ms.handle(stream)

    check firstCalls == 1
    check secondCalls == 0

  asyncTest "test handle `ls`":
    let ms = MultistreamSelect.new()

    var stream: Stream = nil
    let done = newFuture[void]()
    proc testLsHandler(
        proto: seq[byte]
    ) {.async: (raises: [CancelledError, LPStreamError]).} =
      var strProto: string = string.fromBytes(proto)
      check strProto == "\x26/test/proto1/1.0.0\n/test/proto2/1.0.0\n"
      await stream.close()
      done.complete()

    stream = Connection(newTestLsStream(testLsHandler))

    var protocol: LPProtocol = new LPProtocol
    protocol.codecs = @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]
    protocol.handler = noReachHandler
    ms.addHandler("/test/proto1/1.0.0", protocol)
    ms.addHandler("/test/proto2/1.0.0", protocol)
    await ms.handle(stream)
    await done.wait(5.seconds)

  asyncTest "test handle `na`":
    let ms = MultistreamSelect.new()

    var stream: Stream = nil
    proc testNaHandler(
        msg: string
    ): Future[void] {.async: (raises: [CancelledError, LPStreamError]).} =
      check msg == "\x03na\n"
      await stream.close()

    stream = newTestNaStream(testNaHandler)

    var protocol: LPProtocol = new LPProtocol
    protocol.handler = noReachHandler
    ms.addHandler("/unabvailable/proto/1.0.0", protocol)

    await ms.handle(stream)

  asyncTest "e2e - handle":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]

    var protocol: LPProtocol = new LPProtocol
    proc testHandler(
        stream: Stream, proto: string
    ): Future[void] {.async: (raises: [CancelledError]).} =
      check proto == "/test/proto/1.0.0"
      try:
        await stream.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "LPStreamError while handling connection"
      finally:
        await stream.close()

    protocol.codec = "/test/proto/1.0.0"
    protocol.handler = testHandler
    let msListen = MultistreamSelect.new()
    msListen.addHandler("/test/proto/1.0.0", protocol)

    let transport1 = TcpTransport.new(upgrade = Upgrade())
    asyncSpawn transport1.start(ma)

    proc acceptHandler(): Future[void] {.async.} =
      let stream = await transport1.accept()
      await msListen.handle(stream)
      await stream.close()

    let handlerWait = acceptHandler()

    let msDial = MultistreamSelect.new()
    let transport2 = TcpTransport.new(upgrade = Upgrade())
    let stream = await transport2.dial(transport1.addrs[0])

    check (await msDial.select(stream, "/test/proto/1.0.0")) == true

    let hello = string.fromBytes(await stream.readLp(1024))
    check hello == "Hello!"
    await stream.close()

    await transport2.stop()
    await transport1.stop()

    await handlerWait.wait(30.seconds)

  asyncTest "e2e - streams limit":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let blocker = newWaitGroup(1)

    # Start 5 streams which are blocked by `blocker`
    # Try to start a new one, which should fail
    # Unblock the 5 streams, check that we can open a new one
    proc testHandler(
        stream: Stream, proto: string
    ): Future[void] {.async: (raises: [CancelledError]).} =
      try:
        await blocker.wait()
        await stream.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "LPStreamError while handling connection"
      finally:
        await stream.close()

    var protocol: LPProtocol =
      LPProtocol.new(@["/test/proto/1.0.0"], testHandler, maxIncomingStreamsPerPeer = 5)

    protocol.handler = testHandler
    let msListen = MultistreamSelect.new()
    msListen.addHandler("/test/proto/1.0.0", protocol)

    let transport1 = TcpTransport.new(upgrade = Upgrade())
    await transport1.start(ma)

    proc acceptedOne(c: Stream) {.async.} =
      await msListen.handle(c)
      await c.close()

    proc acceptHandler() {.async.} =
      while true:
        let stream = await transport1.accept()
        asyncSpawn acceptedOne(stream)

    var handlerWait = acceptHandler()

    let msDial = MultistreamSelect.new()
    let transport2 = TcpTransport.new(upgrade = Upgrade())

    proc connector() {.async.} =
      let stream = await transport2.dial(transport1.addrs[0])
      check:
        (await msDial.select(stream, "/test/proto/1.0.0")) == true
      check:
        string.fromBytes(await stream.readLp(1024)) == "Hello!"
      await stream.close()

    # Fill up the 5 allowed streams
    var dialers: seq[Future[void]]
    for _ in 0 ..< 5:
      dialers.add(connector())

      # This one will fail during negotiation
    expect LPStreamEOFError:
      try:
        await connector().wait(1.seconds)
      except AsyncTimeoutError:
        raiseAssert "Timeout while waiting for connector"
    # check that the dialers aren't finished
    check:
      (await dialers[0].withTimeout(10.milliseconds)) == false

    # unblock the dialers
    blocker.done()
    await allFutures(dialers)

    # now must work
    await connector()

    await transport2.stop()
    await transport1.stop()

    await handlerWait.cancelAndWait()

  asyncTest "e2e - ls":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]

    let msListen = MultistreamSelect.new()
    var protocol: LPProtocol = new LPProtocol
    protocol.handler = noReachHandler
    msListen.addHandler("/test/proto1/1.0.0", protocol)
    msListen.addHandler("/test/proto2/1.0.0", protocol)

    let transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    let listenFut = transport1.start(ma)

    proc acceptHandler(): Future[void] {.async.} =
      let stream = await transport1.accept()
      try:
        await msListen.handle(stream)
      except LPStreamEOFError as e:
        raiseAssert "unexpected error: " & e.msg
      except LPStreamClosedError as e:
        raiseAssert "unexpected error: " & e.msg
      finally:
        await stream.close()

    let acceptFut = acceptHandler()
    let msDial = MultistreamSelect.new()
    let transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    let stream = await transport2.dial(transport1.addrs[0])

    let ls = await msDial.list(stream)
    let protos: seq[string] = @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]

    check ls == protos

    await stream.close()
    await acceptFut
    await transport2.stop()
    await transport1.stop()
    await listenFut.wait(5.seconds)

  asyncTest "e2e - select one from a list with unsupported protos":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]

    var protocol: LPProtocol = new LPProtocol
    proc testHandler(
        stream: Stream, proto: string
    ): Future[void] {.async: (raises: [CancelledError]).} =
      check proto == "/test/proto/1.0.0"
      try:
        await stream.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "LPStreamError while handling connection"
      finally:
        await stream.close()

    protocol.codec = "/test/proto/1.0.0"
    protocol.handler = testHandler
    let msListen = MultistreamSelect.new()
    msListen.addHandler("/test/proto/1.0.0", protocol)

    let transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    asyncSpawn transport1.start(ma)

    proc acceptHandler(): Future[void] {.async.} =
      let stream = await transport1.accept()
      await msListen.handle(stream)

    let acceptFut = acceptHandler()
    let msDial = MultistreamSelect.new()
    let transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    let stream = await transport2.dial(transport1.addrs[0])

    check (await msDial.select(stream, @["/test/proto/1.0.0", "/test/no/proto/1.0.0"])) ==
      "/test/proto/1.0.0"

    let hello = string.fromBytes(await stream.readLp(1024))
    check hello == "Hello!"

    await stream.close()
    await acceptFut
    await transport2.stop()
    await transport1.stop()

  asyncTest "e2e - select one with both valid":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]

    var protocol: LPProtocol = new LPProtocol
    proc testHandler(
        stream: Stream, proto: string
    ): Future[void] {.async: (raises: [CancelledError]).} =
      try:
        await stream.writeLp(&"Hello from {proto}!")
      except LPStreamError:
        raiseAssert "LPStreamError while handling connection"
      finally:
        await stream.close()

    protocol.codecs = @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]
    protocol.handler = testHandler
    let msListen = MultistreamSelect.new()
    msListen.addHandler("/test/proto1/1.0.0", protocol)
    msListen.addHandler("/test/proto2/1.0.0", protocol)

    let transport1: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    asyncSpawn transport1.start(ma)

    proc acceptHandler(): Future[void] {.async.} =
      let stream = await transport1.accept()
      await msListen.handle(stream)

    let acceptFut = acceptHandler()
    let msDial = MultistreamSelect.new()
    let transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    let stream = await transport2.dial(transport1.addrs[0])

    check (await msDial.select(stream, @["/test/proto2/1.0.0", "/test/proto1/1.0.0"])) ==
      "/test/proto2/1.0.0"

    check string.fromBytes(await stream.readLp(1024)) == "Hello from /test/proto2/1.0.0!"

    await stream.close()
    await acceptFut
    await transport2.stop()
    await transport1.stop()

suite "Multistream :: stream limits":
  teardown:
    checkTrackers()

  let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").get()]
  proc acceptHandler(protocol: LPProtocol, transport: Transport) {.async.} =
    let msListen = MultistreamSelect.new()
    msListen.addHandler(protocol.codecs, protocol)

    proc acceptedOne(c: Stream) {.async.} =
      await msListen.handle(c)
      await c.close()

    while true:
      let stream = await transport.accept()
      asyncSpawn acceptedOne(stream)

  proc makeBlockedHandler(): LPProtoHandler =
    let blocker = newWaitGroup(1)
    # block stream progress in order to make stream occupied while test is running.
    # if handler finishes fast we would never reach limit - it would be a race otherwise.

    proc testHandler(
        stream: Stream, proto: string
    ): Future[void] {.async: (raises: [CancelledError]).} =
      try:
        await blocker.wait()
        await stream.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "LPStreamError while handling connection"
      finally:
        await stream.close()

    return testHandler

  asyncTest "e2e - inbound total stream limit":
    const maxTotalStreams = 3

    let protocol = LPProtocol.new(
      @["/test/proto/1.0.0"],
      makeBlockedHandler(),
      maxIncomingStreamsTotal = maxTotalStreams,
    )

    let transport1 = TcpTransport.new(upgrade = Upgrade())
    await transport1.start(ma)

    let handlerWait = acceptHandler(protocol, transport1)

    let msDial = MultistreamSelect.new()
    let transport2 = TcpTransport.new(upgrade = Upgrade())

    proc connector() {.async.} =
      let stream = await transport2.dial(transport1.addrs[0])
      check:
        (await msDial.select(stream, protocol.codecs[0])) == true
      check:
        string.fromBytes(await stream.readLp(1024)) == "Hello!"
      await stream.close()

    var dialers: seq[Future[void]]
    for _ in 0 ..< maxTotalStreams:
      dialers.add(connector())

    expect LPStreamEOFError:
      try:
        await connector().wait(1.seconds)
      except AsyncTimeoutError:
        raiseAssert "Timeout while waiting for connector"

    await dialers.cancelAndWait()
    await transport2.stop()
    await transport1.stop()
    await handlerWait.cancelAndWait()

  asyncTest "e2e - shared budget across compatible codecs":
    let protocol = LPProtocol.new(
      @["/test/proto1/1.0.0", "/test/proto2/1.0.0"],
      makeBlockedHandler(),
      maxIncomingStreamsTotal = 2,
    )

    let transport1 = TcpTransport.new(upgrade = Upgrade())
    await transport1.start(ma)

    let handlerWait = acceptHandler(protocol, transport1)

    let msDial = MultistreamSelect.new()
    let transport2 = TcpTransport.new(upgrade = Upgrade())

    proc connector(proto: string): Future[void] {.async.} =
      let stream = await transport2.dial(transport1.addrs[0])
      check:
        (await msDial.select(stream, proto)) == true
      check:
        string.fromBytes(await stream.readLp(1024)) == "Hello!"
      await stream.close()

    var d1 = connector("/test/proto1/1.0.0")
    var d2 = connector("/test/proto2/1.0.0")

    expect LPStreamEOFError:
      try:
        await connector("/test/proto1/1.0.0").wait(1.seconds)
      except AsyncTimeoutError:
        raiseAssert "Timeout while waiting for connector"

    await @[d1, d2].cancelAndWait()
    await transport2.stop()
    await transport1.stop()
    await handlerWait.cancelAndWait()

  asyncTest "e2e - inbound budget released on handler completion":
    var handlerCount = 0
    var handlerResolved = newFuture[void]()
    proc testHandler(
        stream: Stream, proto: string
    ): Future[void] {.async: (raises: [CancelledError]).} =
      handlerCount += 1
      try:
        await stream.writeLp("Hello!")
      except LPStreamError:
        raiseAssert "LPStreamError while handling connection"
      finally:
        await stream.close()
        if handlerCount == 1:
          handlerResolved.complete()

    let protocol =
      LPProtocol.new(@["/test/proto/1.0.0"], testHandler, maxIncomingStreamsTotal = 1)

    let transport1 = TcpTransport.new(upgrade = Upgrade())
    await transport1.start(ma)

    let handlerWait = acceptHandler(protocol, transport1)

    let msDial = MultistreamSelect.new()
    let transport2 = TcpTransport.new(upgrade = Upgrade())

    proc connector(): Future[void] {.async.} =
      let stream = await transport2.dial(transport1.addrs[0])
      check:
        (await msDial.select(stream, protocol.codecs[0])) == true
      check:
        string.fromBytes(await stream.readLp(1024)) == "Hello!"
      await stream.close()

    # First stream fills budget, then completes (budget released)
    await connector()
    await handlerResolved.wait(5.seconds)
    check handlerCount == 1
    # Second stream should succeed
    await connector()
    check handlerCount == 2

    await transport2.stop()
    await transport1.stop()
    await handlerWait.cancelAndWait()

  asyncTest "e2e - inbound per-peer limit":
    let protocol = LPProtocol.new(
      @["/test/proto/1.0.0"], makeBlockedHandler(), maxIncomingStreamsPerPeer = 2
    )

    let transport1 = TcpTransport.new(upgrade = Upgrade())
    await transport1.start(ma)

    let handlerWait = acceptHandler(protocol, transport1)

    let msDial = MultistreamSelect.new()
    let transport2 = TcpTransport.new(upgrade = Upgrade())

    proc connector(): Future[void] {.async.} =
      let stream = await transport2.dial(transport1.addrs[0])
      check:
        (await msDial.select(stream, protocol.codecs[0])) == true
      check:
        string.fromBytes(await stream.readLp(1024)) == "Hello!"
      await stream.close()

    var dialers: seq[Future[void]]
    for _ in 0 ..< 2:
      dialers.add(connector())

    expect LPStreamEOFError:
      try:
        await connector().wait(1.seconds)
      except AsyncTimeoutError:
        raiseAssert "Timeout while waiting for connector"

    await dialers.cancelAndWait()
    await transport2.stop()
    await transport1.stop()
    await handlerWait.cancelAndWait()

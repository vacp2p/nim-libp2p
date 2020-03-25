import unittest, strutils, sequtils, strformat, options, stew/byteutils
import chronos
import ../libp2p/connection,
       ../libp2p/multistream,
       ../libp2p/stream/lpstream,
       ../libp2p/stream/bufferstream,
       ../libp2p/connection,
       ../libp2p/multiaddress,
       ../libp2p/transports/transport,
       ../libp2p/transports/tcptransport,
       ../libp2p/protocols/protocol,
       ../libp2p/crypto/crypto,
       ../libp2p/peerinfo,
       ../libp2p/peer

when defined(nimHasUsed): {.used.}

## Mock stream for select test
type
  TestSelectStream = ref object of LPStream
    step*: int

method readOnce*(s: TestSelectStream): Future[seq[byte]] {.async, gcsafe.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      s.step = 2
      return buf
    of 2:
      s.step = 3
      return "/multistream/1.0.0\n".toBytes()
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 18
      s.step = 4
      return buf
    of 4:
      return "/test/proto/1.0.0\n".toBytes()
    else:
      return Na.toBytes()

method write*(s: TestSelectStream, msg: seq[byte], msglen = -1)
  {.async, gcsafe.} = discard

method close(s: TestSelectStream) {.async, gcsafe.} =
  s.isClosed = true

proc newTestSelectStream(): TestSelectStream =
  new result
  result.step = 1

## Mock stream for handles `ls` test
type
  LsHandler = proc(procs: seq[byte]): Future[void] {.gcsafe.}

  TestLsStream = ref object of LPStream
    step*: int
    ls*: LsHandler

method readOnce*(s: TestLsStream): Future[seq[byte]] {.async.} =
  case s.step:
    of 1:
      s.step = 2
      return @[byte(19)]
    of 2:
      s.step = 3
      return "/multistream/1.0.0\n".toBytes()
    of 3:
      s.step = 4
      return @[byte(3)]
    of 4:
      return "ls\n".toBytes()
    else:
      return Na.toBytes()

method write*(s: TestLsStream, msg: seq[byte], msglen = -1) {.async, gcsafe.} =
  if s.step == 4:
    await s.ls(msg)

method write*(s: TestLsStream, msg: string, msglen = -1)
  {.async, gcsafe.} = discard

method close(s: TestLsStream) {.async, gcsafe.} =
  s.isClosed = true

proc newTestLsStream(ls: LsHandler): TestLsStream {.gcsafe.} =
  new result
  result.ls = ls
  result.step = 1

## Mock stream for handles `na` test
type
  NaHandler = proc(procs: string): Future[void] {.gcsafe.}

  TestNaStream = ref object of LPStream
    step*: int
    na*: NaHandler

method readOnce*(s: TestNaStream): Future[seq[byte]] {.async, gcsafe.} =
  case s.step:
    of 1:
      s.step = 2
      return @[byte(19)]
    of 2:
      s.step = 3
      return "/multistream/1.0.0\n".toBytes()
    of 3:
      s.step = 4
      return @[byte(18)]
    of 4:
      return "/test/proto/1.0.0\n".toBytes()
    else:
      return Na.toBytes()

method write*(s: TestNaStream, msg: string, msglen = -1) {.async, gcsafe.} =
  if s.step == 4:
    await s.na(msg)

method close(s: TestNaStream) {.async, gcsafe.} =
  s.isClosed = true

proc newTestNaStream(na: NaHandler): TestNaStream =
  new result
  result.na = na
  result.step = 1

suite "Multistream select":
  test "test select custom proto":
    proc testSelect(): Future[bool] {.async.} =
      let ms = newMultistream()
      let conn = newConnection(newTestSelectStream())
      result = (await ms.select(conn, @["/test/proto/1.0.0"])) == "/test/proto/1.0.0"

    check:
      waitFor(testSelect()) == true

  test "test handle custom proto":
    proc testHandle(): Future[bool] {.async.} =
      let ms = newMultistream()
      let conn = newConnection(newTestSelectStream())

      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection,
                       proto: string):
                       Future[void] {.async, gcsafe.} =
        check proto == "/test/proto/1.0.0"
        await conn.close()

      protocol.handler = testHandler
      ms.addHandler("/test/proto/1.0.0", protocol)
      await ms.handle(conn)
      result = true

    check:
      waitFor(testHandle()) == true

  test "test handle `ls`":
    proc testLs(): Future[bool] {.async.} =
      let ms = newMultistream()

      proc testLsHandler(proto: seq[byte]) {.async, gcsafe.} # forward declaration
      let conn = newConnection(newTestLsStream(testLsHandler))
      proc testLsHandler(proto: seq[byte]) {.async, gcsafe.} =
        var strProto: string = cast[string](proto)
        check strProto == "\x26/test/proto1/1.0.0\n/test/proto2/1.0.0\n"
        await conn.close()

      proc testHandler(conn: Connection, proto: string): Future[void]
        {.async, gcsafe.} = discard
      var protocol: LPProtocol = new LPProtocol
      protocol.handler = testHandler
      ms.addHandler("/test/proto1/1.0.0", protocol)
      ms.addHandler("/test/proto2/1.0.0", protocol)
      await ms.handle(conn)
      result = true

    check:
      waitFor(testLs()) == true

  test "test handle `na`":
    proc testNa(): Future[bool] {.async.} =
      let ms = newMultistream()

      proc testNaHandler(msg: string): Future[void] {.async, gcsafe.}
      let conn = newConnection(newTestNaStream(testNaHandler))

      proc testNaHandler(msg: string): Future[void] {.async, gcsafe.} =
        check cast[string](msg) == Na
        await conn.close()

      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection,
                       proto: string):
                       Future[void] {.async, gcsafe.} = discard
      protocol.handler = testHandler
      ms.addHandler("/unabvailable/proto/1.0.0", protocol)

      await ms.handle(conn)
      result = true

    check:
      waitFor(testNa()) == true

  test "e2e - handle":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection,
                       proto: string):
                       Future[void] {.async, gcsafe.} =
        check proto == "/test/proto/1.0.0"
        await conn.writeLp("Hello!")
        await conn.close()

      protocol.handler = testHandler
      let msListen = newMultistream()
      msListen.addHandler("/test/proto/1.0.0", protocol)

      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)

      let transport1: TcpTransport = newTransport(TcpTransport)
      asyncCheck transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      check (await msDial.select(conn, "/test/proto/1.0.0")) == true

      let hello = cast[string](await conn.readLp())
      result = hello == "Hello!"
      await conn.close()

    check:
      waitFor(endToEnd()) == true

  test "e2e - ls":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      let msListen = newMultistream()
      var protocol: LPProtocol = new LPProtocol
      protocol.handler = proc(conn: Connection, proto: string) {.async, gcsafe.} =
        await conn.close()
      proc testHandler(conn: Connection,
                       proto: string):
                       Future[void] {.async.} = discard
      protocol.handler = testHandler
      msListen.addHandler("/test/proto1/1.0.0", protocol)
      msListen.addHandler("/test/proto2/1.0.0", protocol)

      let transport1: TcpTransport = newTransport(TcpTransport)
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)
      asyncCheck transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      let ls = await msDial.list(conn)
      let protos: seq[string] = @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]
      await conn.close()
      result = ls == protos

    check:
      waitFor(endToEnd()) == true

  test "e2e - select one from a list with unsupported protos":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection,
                       proto: string):
                       Future[void] {.async, gcsafe.} =
        check proto == "/test/proto/1.0.0"
        await conn.writeLp("Hello!")
        await conn.close()

      protocol.handler = testHandler
      let msListen = newMultistream()
      msListen.addHandler("/test/proto/1.0.0", protocol)

      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)

      let transport1: TcpTransport = newTransport(TcpTransport)
      asyncCheck transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      check (await msDial.select(conn,
        @["/test/proto/1.0.0", "/test/no/proto/1.0.0"])) == "/test/proto/1.0.0"

      let hello = cast[string](await conn.readLp())
      result = hello == "Hello!"
      await conn.close()

    check:
      waitFor(endToEnd()) == true

  test "e2e - select one with both valid":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection,
                       proto: string):
                       Future[void] {.async, gcsafe.} =
        await conn.writeLp(&"Hello from {proto}!")
        await conn.close()

      protocol.handler = testHandler
      let msListen = newMultistream()
      msListen.addHandler("/test/proto1/1.0.0", protocol)
      msListen.addHandler("/test/proto2/1.0.0", protocol)

      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)

      let transport1: TcpTransport = newTransport(TcpTransport)
      asyncCheck transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      check (await msDial.select(conn, @["/test/proto2/1.0.0", "/test/proto1/1.0.0"])) == "/test/proto2/1.0.0"

      result = cast[string](await conn.readLp()) == "Hello from /test/proto2/1.0.0!"
      await conn.close()

    check:
      waitFor(endToEnd()) == true

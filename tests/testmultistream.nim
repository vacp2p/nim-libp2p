import unittest, strutils, strformat, stew/byteutils
import chronos
import ../libp2p/errors,
       ../libp2p/multistream,
       ../libp2p/stream/bufferstream,
       ../libp2p/stream/connection,
       ../libp2p/multiaddress,
       ../libp2p/transports/transport,
       ../libp2p/transports/tcptransport,
       ../libp2p/protocols/protocol

import ./helpers

when defined(nimHasUsed): {.used.}

## Mock stream for select test
type
  TestSelectStream = ref object of Connection
    step*: int

method readOnce*(s: TestSelectStream,
                 pbytes: pointer,
                 nbytes: int): Future[int] {.async, gcsafe.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 2
      return buf.len
    of 2:
      var buf = "/multistream/1.0.0\n"
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 3
      return buf.len
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 18
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 4
      return buf.len
    of 4:
      var buf = "/test/proto/1.0.0\n"
      copyMem(pbytes, addr buf[0], buf.len())
      return buf.len
    else:
      copyMem(pbytes,
              cstring("\0x3na\n"),
              "\0x3na\n".len())

      return "\0x3na\n".len()

method write*(s: TestSelectStream, msg: seq[byte]) {.async, gcsafe.} = discard

method close(s: TestSelectStream) {.async, gcsafe.} =
  s.isClosed = true
  s.isEof = true

proc newTestSelectStream(): TestSelectStream =
  new result
  result.step = 1

## Mock stream for handles `ls` test
type
  LsHandler = proc(procs: seq[byte]): Future[void] {.gcsafe.}

  TestLsStream = ref object of Connection
    step*: int
    ls*: LsHandler

method readOnce*(s: TestLsStream,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 2
      return buf.len()
    of 2:
      var buf = "/multistream/1.0.0\n"
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 3
      return buf.len()
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 3
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 4
      return buf.len()
    of 4:
      var buf = "ls\n"
      copyMem(pbytes, addr buf[0], buf.len())
      return buf.len()
    else:
      var buf = "na\n"
      copyMem(pbytes, addr buf[0], buf.len())
      return buf.len()

method write*(s: TestLsStream, msg: seq[byte]) {.async, gcsafe.} =
  if s.step == 4:
    await s.ls(msg)

method close(s: TestLsStream) {.async, gcsafe.} =
  s.isClosed = true
  s.isEof = true

proc newTestLsStream(ls: LsHandler): TestLsStream {.gcsafe.} =
  new result
  result.ls = ls
  result.step = 1

## Mock stream for handles `na` test
type
  NaHandler = proc(procs: string): Future[void] {.gcsafe.}

  TestNaStream = ref object of Connection
    step*: int
    na*: NaHandler

method readOnce*(s: TestNaStream,
                 pbytes: pointer,
                 nbytes: int):
                 Future[int] {.async, gcsafe.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 2
      return buf.len()
    of 2:
      var buf = "/multistream/1.0.0\n"
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 3
      return buf.len()
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 18
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 4
      return buf.len()
    of 4:
      var buf = "/test/proto/1.0.0\n"
      copyMem(pbytes, addr buf[0], buf.len())
      return buf.len()
    else:
      copyMem(pbytes,
              cstring("\0x3na\n"),
              "\0x3na\n".len())

      return "\0x3na\n".len()

method write*(s: TestNaStream, msg: seq[byte]) {.async, gcsafe.} =
  if s.step == 4:
    await s.na(string.fromBytes(msg))

method close(s: TestNaStream) {.async, gcsafe.} =
  s.isClosed = true
  s.isEof = true

proc newTestNaStream(na: NaHandler): TestNaStream =
  new result
  result.na = na
  result.step = 1

suite "Multistream select":
  teardown:
    for tracker in testTrackers():
      # echo tracker.dump()
      check tracker.isLeaked() == false

  test "test select custom proto":
    proc testSelect(): Future[bool] {.async.} =
      let ms = newMultistream()
      let conn = newTestSelectStream()
      result = (await ms.select(conn, @["/test/proto/1.0.0"])) == "/test/proto/1.0.0"
      await conn.close()

    check:
      waitFor(testSelect()) == true

  test "test handle custom proto":
    proc testHandle(): Future[bool] {.async.} =
      let ms = newMultistream()
      let conn = newTestSelectStream()

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
      let conn = Connection(newTestLsStream(testLsHandler))
      let done = newFuture[void]()
      proc testLsHandler(proto: seq[byte]) {.async, gcsafe.} =
        var strProto: string = string.fromBytes(proto)
        check strProto == "\x26/test/proto1/1.0.0\n/test/proto2/1.0.0\n"
        await conn.close()
        done.complete()

      proc testHandler(conn: Connection, proto: string): Future[void]
        {.async, gcsafe.} = discard
      var protocol: LPProtocol = new LPProtocol
      protocol.handler = testHandler
      ms.addHandler("/test/proto1/1.0.0", protocol)
      ms.addHandler("/test/proto2/1.0.0", protocol)
      await ms.handle(conn)
      result = true

      await done.wait(5.seconds)

    check:
      waitFor(testLs()) == true

  test "test handle `na`":
    proc testNa(): Future[bool] {.async.} =
      let ms = newMultistream()

      proc testNaHandler(msg: string): Future[void] {.async, gcsafe.}
      let conn = newTestNaStream(testNaHandler)

      proc testNaHandler(msg: string): Future[void] {.async, gcsafe.} =
        echo msg
        check msg == Na
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
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

      let
        handlerWait1 = newFuture[void]()
        handlerWait2 = newFuture[void]()

      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection,
                       proto: string):
                       Future[void] {.async, gcsafe.} =
        check proto == "/test/proto/1.0.0"
        await conn.writeLp("Hello!")
        await conn.close()
        handlerWait1.complete()

      protocol.handler = testHandler
      let msListen = newMultistream()
      msListen.addHandler("/test/proto/1.0.0", protocol)

      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)
        await conn.close()
        handlerWait2.complete()

      let transport1: TcpTransport = TcpTransport.init()
      asyncCheck transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      check (await msDial.select(conn, "/test/proto/1.0.0")) == true

      let hello = string.fromBytes(await conn.readLp(1024))
      result = hello == "Hello!"
      await conn.close()

      await transport2.close()
      await transport1.close()

      await allFuturesThrowing(
        handlerWait1.wait(30.seconds),
        handlerWait2.wait(30.seconds))

    check:
      waitFor(endToEnd()) == true

  test "e2e - ls":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

      let
        handlerWait = newFuture[void]()

      let msListen = newMultistream()
      var protocol: LPProtocol = new LPProtocol
      protocol.handler = proc(conn: Connection, proto: string) {.async, gcsafe.} =
        # never reached
        discard

      proc testHandler(conn: Connection,
                       proto: string):
                       Future[void] {.async.} =
        # never reached
        discard

      protocol.handler = testHandler
      msListen.addHandler("/test/proto1/1.0.0", protocol)
      msListen.addHandler("/test/proto2/1.0.0", protocol)

      let transport1: TcpTransport = TcpTransport.init()
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        try:
          await msListen.handle(conn)
        except LPStreamEOFError:
          discard
        except LPStreamClosedError:
          discard
        finally:
          await conn.close()

      let listenFut = transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      let ls = await msDial.list(conn)
      let protos: seq[string] = @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]

      result = ls == protos

      await conn.close()
      await transport2.close()
      await transport1.close()
      discard await listenFut.wait(5.seconds)

    check:
      waitFor(endToEnd()) == true

  test "e2e - select one from a list with unsupported protos":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

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

      let transport1: TcpTransport = TcpTransport.init()
      asyncCheck transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      check (await msDial.select(conn,
        @["/test/proto/1.0.0", "/test/no/proto/1.0.0"])) == "/test/proto/1.0.0"

      let hello = string.fromBytes(await conn.readLp(1024))
      result = hello == "Hello!"

      await conn.close()
      await transport2.close()
      await transport1.close()


    check:
      waitFor(endToEnd()) == true

  test "e2e - select one with both valid":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()

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

      let transport1: TcpTransport = TcpTransport.init()
      asyncCheck transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)

      check (await msDial.select(conn, @["/test/proto2/1.0.0", "/test/proto1/1.0.0"])) == "/test/proto2/1.0.0"

      result = string.fromBytes(await conn.readLp(1024)) == "Hello from /test/proto2/1.0.0!"

      await conn.close()
      await transport2.close()
      await transport1.close()

    check:
      waitFor(endToEnd()) == true

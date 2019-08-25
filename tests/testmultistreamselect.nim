import unittest, strutils, sequtils, sugar
import chronos
import ../libp2p/connection, ../libp2p/multistreamselect, 
  ../libp2p/readerwriter, ../libp2p/connection, ../libp2p/multiaddress,
  ../libp2p/transport, ../libp2p/tcptransport

## Mock stream for select test
type
  TestSelectStream = ref object of ReadWrite
    step*: int

method readExactly*(s: TestSelectStream, pbytes: pointer, nbytes: int): Future[void] {.async.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 2
    of 2:
      var buf = "/multistream/1.0.0\n"
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 3
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 18
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 4
    of 4:
      var buf = "/test/proto/1.0.0\n"
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
    else: 
      copyMem(cast[pointer](cast[uint](pbytes)), cstring("\0x3na\n"), "\0x3na\n".len())

proc newTestSelectStream(): TestSelectStream =
  new result
  result.step = 1

## Mock stream for handles test
type
  TestHandlesStream = ref object of ReadWrite
    step*: int

method readExactly*(s: TestHandlesStream, pbytes: pointer, nbytes: int): Future[void] {.async.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 2
    of 2:
      var buf = "/multistream/1.0.0\n"
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 3
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 18
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 4
    of 4:
      var buf = "/test/proto/1.0.0\n"
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
    else: 
      copyMem(cast[pointer](cast[uint](pbytes)), cstring("\0x3na\n"), "\0x3na\n".len())

proc newTestHandlesStream(): TestHandlesStream =
  new result
  result.step = 1

## Mock stream for handles `ls` test
type
  LsHandler = proc(procs: seq[byte]): Future[void]

  TestLsStream = ref object of ReadWrite
    step*: int
    ls*: LsHandler

method readExactly*(s: TestLsStream, pbytes: pointer, nbytes: int): Future[void] {.async.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 2
    of 2:
      var buf = "/multistream/1.0.0\n"
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 3
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 3
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 4
    of 4:
      var buf = "ls\n"
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
    else: 
      copyMem(cast[pointer](cast[uint](pbytes)), cstring("\0x3na\n"), "\0x3na\n".len())

method write*(s: TestLsStream, msg: seq[byte], msglen = -1) {.async.} =
  if s.step == 4:
    await s.ls(msg)

proc newTestLsStream(ls: LsHandler): TestLsStream =
  new result
  result.ls = ls
  result.step = 1

## Mock stream for handles `na` test
type
  NaHandler = proc(procs: string): Future[void]

  TestNaStream = ref object of ReadWrite
    step*: int
    na*: NaHandler

method readExactly*(s: TestNaStream, pbytes: pointer, nbytes: int): Future[void] {.async.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 2
    of 2:
      var buf = "/multistream/1.0.0\n"
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 3
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 18
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 4
    of 4:
      var buf = "/test/proto/1.0.0\n"
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
    else: 
      copyMem(cast[pointer](cast[uint](pbytes)), cstring("\0x3na\n"), "\0x3na\n".len())

method write*(s: TestNaStream, msg: string, msglen = -1) {.async.} =
  if s.step == 4:
    await s.na(msg)

proc newTestNaStream(na: NaHandler): TestNaStream =
  new result
  result.na = na
  result.step = 1

suite "Multistream select":
  test "test select custom proto":
    proc testSelect(): Future[bool] {.async.} =
      let ms = newMultistream()
      let conn = newConnection(newTestSelectStream())
      result = await ms.select(conn, "/test/proto/1.0.0")

    check:
      waitFor(testSelect()) == true

  test "test handle custom proto":
    proc testHandle(): Future[bool] {.async.} =
      let ms = newMultistream()
      let conn = newConnection(newTestHandlesStream())

      proc testHandler(conn: Connection, proto: string): Future[void] {.async.} =
        check proto == "/test/proto/1.0.0"

      ms.addHandler("/test/proto/1.0.0", testHandler)
      await ms.handle(conn)
      result = true

    check:
      waitFor(testHandle()) == true
  
  test "test handle `ls`":
    proc testLs(): Future[bool] {.async.} =
      let ms = newMultistream()

      proc testLs(proto: seq[byte]): Future[void] {.async.}
      let conn = newConnection(newTestLsStream(testLs))

      proc testLs(proto: seq[byte]): Future[void] {.async.} =
        var strProto: string = cast[string](proto)
        check strProto == "\x26/test/proto1/1.0.0\n/test/proto2/1.0.0\n"
        await conn.close()

      proc testHandler(conn: Connection, proto: string): Future[void] {.async.} = discard
      ms.addHandler("/test/proto1/1.0.0", testHandler)
      ms.addHandler("/test/proto2/1.0.0", testHandler)
      await ms.handle(conn)
      result = true

    check:
      waitFor(testLs()) == true

  test "test handle `na`":
    proc testNa(): Future[bool] {.async.} =
      let ms = newMultistream()

      proc testNa(msg: string): Future[void] {.async.}
      let conn = newConnection(newTestNaStream(testNa))

      proc testNa(msg: string): Future[void] {.async.} =
        check cast[string](msg) == "\x3na\n"
        await conn.close()

      proc testHandler(conn: Connection, proto: string): Future[void] {.async.} = discard
      ms.addHandler("/unabvailable/proto/1.0.0", testHandler)

      await ms.handle(conn)
      result = true

    check:
      waitFor(testNa()) == true

  test "end to end":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53340")
      proc testHandler(conn: Connection, proto: string): Future[void] {.async.} =
        check proto == "/test/proto/1.0.0"
        await conn.writeLp("Hello!")
        await conn.close()

      let msListen = newMultistream()
      msListen.addHandler("/test/proto/1.0.0", testHandler)

      proc connHandler(conn: Connection): Future[void] {.async ,gcsafe.} =
        await msListen.handle(conn)

      let transport1: TcpTransport = newTransport(TcpTransport)
      await transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)
      
      let res = await msDial.select(conn, "/test/proto/1.0.0")
      check res == true

      let hello = cast[string](await conn.readLp())
      result = hello == "Hello!"
      await conn.close()

    check:
      waitFor(endToEnd()) == true

  test "end to end - ls":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53341")

      let msListen = newMultistream()
      proc testHandler(conn: Connection, proto: string): Future[void] {.async.} = discard
      msListen.addHandler("/test/proto1/1.0.0", testHandler)
      msListen.addHandler("/test/proto2/1.0.0", testHandler)

      let transport1: TcpTransport = newTransport(TcpTransport)
      proc connHandler(conn: Connection): Future[void] {.async ,gcsafe.} = 
        await msListen.handle(conn)

      await transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)
      
      let ls = await msDial.list(conn)
      let protos: seq[string] = @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]
      await conn.close()
      result = ls == protos

    check:
      waitFor(endToEnd()) == true

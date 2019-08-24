import unittest, strutils, sequtils, sugar
import chronos
import ../libp2p/connection, ../libp2p/multistreamselect, 
  ../libp2p/readerwriter, ../libp2p/connection

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

## Mock stream for handles test
type
  LsHandler = proc(procs: seq[byte]): Future[void]

  TestLsStream = ref object of ReadWrite
    step*: int
    ls*: proc(procs: seq[byte]): Future[void]

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

      let protos: seq[string] = @["\x13/test/proto1/1.0.0\n", "\x13/test/proto2/1.0.0\n"]
      proc testLs(proto: seq[byte]): Future[void] {.async.} =
        var strProto: string = cast[string](proto)
        check strProto in protos
        await conn.close()

      proc testHandler(conn: Connection, proto: string): Future[void] {.async.} = discard
      ms.addHandler("/test/proto1/1.0.0", testHandler)
      ms.addHandler("/test/proto2/1.0.0", testHandler)
      await ms.handle(conn)
      result = true

    check:
      waitFor(testLs()) == true

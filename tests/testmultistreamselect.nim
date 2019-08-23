import unittest, strutils, sequtils
import chronos
import ../libp2p/connection, ../libp2p/multistreamselect, 
  ../libp2p/readerwriter, ../libp2p/connection

## Stream for select test
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

## Stream for handles test
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

suite "Multistream select":
  # test "test select custom proto":
  #   proc testSelect(): Future[bool] {.async.} =
  #     let ms = newMultistream()
  #     let conn = newConnection(newTestSelectStream())
  #     result = await ms.select(conn, "/test/proto/1.0.0")

  #   check:
  #     waitFor(testSelect()) == true

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
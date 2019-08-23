import unittest, strutils, sequtils
import chronos
import ../libp2p/connection, ../libp2p/multistreamselect, 
  ../libp2p/readerwriter, ../libp2p/connection

# custom select stream
type
  TestStream = ref object of ReadWrite
    step*: int

method readExactly*(s: TestStream, pbytes: pointer, nbytes: int): Future[void] {.async.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(cast[pointer](cast[uint](pbytes)), addr buf[0], buf.len())
      s.step = 2
    of 2:
      var buf = MultiCodec
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

proc newTestStream(): TestStream =
  new result
  result.step = 1

suite "Multistream select":
  test "test select":
    proc testSelect(): Future[bool] {.async.} =
      let ms = newMultistream()
      let conn = newConnection(newTestStream())
      result = await ms.select(conn, "/test/proto/1.0.0")

    check:
      waitFor(testSelect()) == true
  
  # test "test handle":
  #   proc testHandle(): Future[bool] {.async.} =
  #     let ms = newMultistream()
  #     let conn = newConnection(newTestStream())

  #     proc testHandler(conn: Connection, proto: string): Future[void] =
  #       check proto == "/test/proto/1.0.0"

  #     ms.addHandler("/test/proto/1.0.0", testHandler)
  #     await ms.handle(conn)

  #   check:
  #     waitFor(testHandle()) == true
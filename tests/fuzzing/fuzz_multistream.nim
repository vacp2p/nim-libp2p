import testutils/fuzzing
import chronos

import ../../libp2p/stream/connection,
       ../../libp2p/stream/bufferstream,
       ../../libp2p/multistream,
       ../../libp2p/protocols/protocol

type
  TestBufferStream* = ref object of BufferStream

method write*(s: TestBufferStream, msg: seq[byte]) {.async.} =
  discard

proc fuzzedStream*(s: seq[byte]): Connection =
  let res = TestBufferStream()
  res.initStream()
  discard res.pushData(s)
  return res


test:
  proc atest(s: seq[byte]) {.async.} =
    let ms = MultistreamSelect.new()
    let conn = fuzzedStream(s)
    try:
      discard await ms.select(conn, @["/test/proto/1.0.0"]).wait(1.milliseconds)
    except AsyncTimeoutError, MultiStreamError, MaxSizeError, InvalidVarintError: discard
    await conn.close()

  proc btest(s: seq[byte]) {.async.} =
    let ms = MultistreamSelect.new()
    let conn = fuzzedStream(s)

    var protocol: LPProtocol = new LPProtocol
    proc testHandler(conn: Connection,
                      proto: string):
                      Future[void] {.async, gcsafe.} =
      doAssert proto == "/test/proto/1.0.0"

    protocol.handler = testHandler
    ms.addHandler("/test/proto/1.0.0", protocol)
    try:
      await ms.handle(conn).wait(1.milliseconds)
    except AsyncTimeoutError: discard
  waitFor(atest(@payload))
  waitFor(btest(@payload))

import unittest, strutils, sequtils, sugar, strformat
import chronos
import ../libp2p/connection, ../libp2p/multistream,
       ../libp2p/stream/lpstream, ../libp2p/connection, 
       ../libp2p/multiaddress, ../libp2p/transport, 
       ../libp2p/tcptransport, ../libp2p/protocol,
       ../libp2p/crypto/crypto, ../libp2p/peerinfo,
       ../libp2p/peer

## Mock stream for select test
type
  TestSelectStream = ref object of LPStream
    step*: int

method readExactly*(s: TestSelectStream,
                    pbytes: pointer,
                    nbytes: int): Future[void] {.async, gcsafe.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 2
    of 2:
      var buf = "/multistream/1.0.0\n"
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 3
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 18
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 4
    of 4:
      var buf = "/test/proto/1.0.0\n"
      copyMem(pbytes, addr buf[0], buf.len())
    else:
      copyMem(pbytes,
              cstring("\0x3na\n"),
              "\0x3na\n".len())

method write*(s: TestSelectStream, msg: string, msglen = -1) 
  {.async, gcsafe.} = discard

proc newTestSelectStream(): TestSelectStream =
  new result
  result.step = 1

## Mock stream for handles `ls` test
type
  LsHandler = proc(procs: seq[byte]): Future[void]

  TestLsStream = ref object of LPStream
    step*: int
    ls*: LsHandler

method readExactly*(s: TestLsStream,
                    pbytes: pointer,
                    nbytes: int): 
                    Future[void] {.async, gcsafe.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 2
    of 2:
      var buf = "/multistream/1.0.0\n"
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 3
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 3
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 4
    of 4:
      var buf = "ls\n"
      copyMem(pbytes, addr buf[0], buf.len())
    else:
      copyMem(pbytes, cstring("\0x3na\n"), "\0x3na\n".len())

method write*(s: TestLsStream, msg: seq[byte], msglen = -1) {.async, gcsafe.} =
  if s.step == 4:
    await s.ls(msg)

method write*(s: TestLsStream, msg: string, msglen = -1)
  {.async, gcsafe.} = discard

method close*(s: TestLsStream) {.async, gcsafe.} = discard

proc newTestLsStream(ls: LsHandler): TestLsStream =
  new result
  result.ls = ls
  result.step = 1

## Mock stream for handles `na` test
type
  NaHandler = proc(procs: string): Future[void]

  TestNaStream = ref object of LPStream
    step*: int
    na*: NaHandler

method readExactly*(s: TestNaStream,
                    pbytes: pointer,
                    nbytes: int): 
                    Future[void] {.async, gcsafe.} =
  case s.step:
    of 1:
      var buf = newSeq[byte](1)
      buf[0] = 19
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 2
    of 2:
      var buf = "/multistream/1.0.0\n"
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 3
    of 3:
      var buf = newSeq[byte](1)
      buf[0] = 18
      copyMem(pbytes, addr buf[0], buf.len())
      s.step = 4
    of 4:
      var buf = "/test/proto/1.0.0\n"
      copyMem(pbytes, addr buf[0], buf.len())
    else:
      copyMem(pbytes,
              cstring("\0x3na\n"),
              "\0x3na\n".len())

method write*(s: TestNaStream, msg: string, msglen = -1) {.async, gcsafe.} =
  if s.step == 4:
    await s.na(msg)

method close*(s: TestNaStream) {.async, gcsafe.} = discard

proc newTestNaStream(na: NaHandler): TestNaStream =
  new result
  result.na = na
  result.step = 1

suite "Multistream select":
  test "test select custom proto":
    proc testSelect(): Future[bool] {.async.} =
      let ms = newMultistream()
      let conn = newConnection(newTestSelectStream())
      result = await ms.select(conn, @["/test/proto/1.0.0"])

    check:
      waitFor(testSelect()) == true

  test "test handle custom proto":
    proc testHandle(): Future[bool] {.async.} =
      let ms = newMultistream()
      let conn = newConnection(newTestSelectStream())

      let seckey = PrivateKey.random(RSA)
      var peerInfo: PeerInfo
      peerInfo.peerId = PeerID.init(seckey)
      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection,
                       proto: string): 
                       Future[void] {.async, gcsafe.} =
        check proto == "/test/proto/1.0.0"

      protocol.handler = testHandler
      ms.addHandler("/test/proto/1.0.0", protocol)
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

      let seckey = PrivateKey.random(RSA)
      var peerInfo: PeerInfo
      peerInfo.peerId = PeerID.init(seckey)
      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection,
                       proto: string): 
                       Future[void] {.async, gcsafe.} = discard
      
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

      proc testNa(msg: string): Future[void] {.async.}
      let conn = newConnection(newTestNaStream(testNa))

      proc testNa(msg: string): Future[void] {.async.} =
        check cast[string](msg) == "\x3na\n"
        await conn.close()

      let seckey = PrivateKey.random(RSA)
      var peerInfo: PeerInfo
      peerInfo.peerId = PeerID.init(seckey)
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
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53350")

      let seckey = PrivateKey.random(RSA)
      var peerInfo: PeerInfo
      peerInfo.peerId = PeerID.init(seckey)
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
      await transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)

      let res = await msDial.select(conn, @["/test/proto/1.0.0"])
      check res == true

      let hello = cast[string](await conn.readLp())
      result = hello == "Hello!"
      await conn.close()

    check:
      waitFor(endToEnd()) == true

  test "e2e - ls":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53351")

      let msListen = newMultistream()
      let seckey = PrivateKey.random(RSA)
      var peerInfo: PeerInfo
      peerInfo.peerId = PeerID.init(seckey)
      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection,
                       proto: string): 
                       Future[void] {.async.} = discard
      protocol.handler = testHandler
      msListen.addHandler("/test/proto1/1.0.0", protocol)
      msListen.addHandler("/test/proto2/1.0.0", protocol)

      let transport1: TcpTransport = newTransport(TcpTransport)
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
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

  test "e2e - select one of one invalid":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53352")

      let seckey = PrivateKey.random(RSA)
      var peerInfo: PeerInfo
      peerInfo.peerId = PeerID.init(seckey)
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
      await transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)

      let res = await msDial.select(conn, @["/test/proto/1.0.0", "/test/no/proto/1.0.0"])
      check res == true

      let hello = cast[string](await conn.readLp())
      result = hello == "Hello!"
      await conn.close()

    check:
      waitFor(endToEnd()) == true

  test "e2e - select one with both valid":
    proc endToEnd(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53353")

      let seckey = PrivateKey.random(RSA)
      var peerInfo: PeerInfo
      peerInfo.peerId = PeerID.init(seckey)
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
      await transport1.listen(ma, connHandler)

      let msDial = newMultistream()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)

      let res = await msDial.select(conn, @["/test/proto2/1.0.0", "/test/proto1/1.0.0"])
      check res == true

      let hello = cast[string](await conn.readLp())
      result = hello == "Hello from /test/proto2/1.0.0!"
      await conn.close()

    check:
      waitFor(endToEnd()) == true
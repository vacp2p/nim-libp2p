import unittest, strutils, sequtils
import chronos, stew/byteutils
import crypto/crypto,
       streams/[stream, pushable, connection, utils, lenprefixed],
       transports/[transport, tcptransport],
       protocols/protocol,
       multistream,
       multiaddress,
       peerinfo,
       peer

when defined(nimHasUsed): {.used.}

const
  CodecString = "/multistream/1.0.0"
  TestProtoString = "/test/proto/1.0.0"
  TestString = "HELLO"

  CodecBytes = @[19.byte, 47.byte, 109.byte,
                 117.byte, 108.byte, 116.byte,
                 105.byte, 115.byte, 116.byte,
                 114.byte, 101.byte, 97.byte,
                 109.byte, 47.byte, 49.byte,
                 46.byte, 48.byte, 46.byte,
                 48.byte, 10.byte]

  TestProtoBytes = @[18.byte, 47.byte, 116.byte,
                     101.byte, 115.byte, 116.byte,
                     47.byte, 112.byte, 114.byte,
                     111.byte, 116.byte, 111.byte,
                     47.byte, 49.byte, 46.byte, 48.byte,
                     46.byte, 48.byte, 10.byte]

suite "Multistream select":
  test "test select custom proto":
    proc test() {.async.} =
      let pushable = BytePushable.init()
      pushable.sinkImpl = proc(s: Stream[seq[byte]]): Sink[seq[byte]] {.gcsafe.} =
        return proc(i: Source[seq[byte]]) {.async, gcsafe.} =
          check: (await i()) == CodecBytes
          check: (await i()) == TestProtoBytes

          await pushable.push(CodecBytes)
          await pushable.push(TestProtoBytes)

      let conn = Connection.init(pushable)
      var ms = MultistreamSelect.init()

      check: (await ms.select(conn, @[TestProtoString])) == TestProtoString
      await pushable.close()

    waitFor(test())

  test "test handle custom proto":
    proc test() {.async.} =
      var ms = MultistreamSelect.init()
      let pushable = BytePushable.init()
      pushable.sinkImpl = proc(s: Stream[seq[byte]]): Sink[seq[byte]] {.gcsafe.} =
        return proc(i: Source[seq[byte]]) {.async.} =
          check: (await i()) == CodecBytes
          check: (await i()) == TestProtoBytes
          await pushable.close()

      let conn = Connection.init(pushable)

      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection, proto: string):
                       Future[void] {.async, gcsafe.} =
        check: proto == TestProtoString
        await conn.close()

      protocol.handler = testHandler
      ms.addHandler(TestProtoString, protocol)
      var handlerFut = ms.handle(conn)

      await pushable.push(CodecBytes)
      await pushable.push(TestProtoBytes)
      await pushable.close()

      await handlerFut

    waitFor(test())

  test "test handle `ls`":
    proc test() {.async.} =
      var ms = MultistreamSelect.init()
      let pushable = BytePushable.init()
      pushable.sinkImpl = proc(s: Stream[seq[byte]]): Sink[seq[byte]] {.gcsafe.} =
        return proc(i: Source[seq[byte]]) {.async.} =
          check: (await i()) == CodecBytes
          check: (await i()) == ("\x26/test/proto1/1.0.0\n" &
                                "/test/proto2/1.0.0\n").toBytes()

      let conn = Connection.init(pushable)
      var protocol: LPProtocol = new LPProtocol

      protocol.handler = proc(conn: Connection, proto: string):
        Future[void] {.async, gcsafe.} = discard

      ms.addHandler("/test/proto1/1.0.0", protocol)
      ms.addHandler("/test/proto2/1.0.0", protocol)

      var handlerFut = ms.handle(conn)

      await pushable.push(CodecBytes) # handshake
      await pushable.push("\3ls\n".toBytes())
      await pushable.close()

      await handlerFut

    waitFor(test())

  test "test handle `na`":
    proc test() {.async.} =
      var ms = MultistreamSelect.init()
      let pushable = BytePushable.init()
      pushable.sinkImpl = proc(s: Stream[seq[byte]]): Sink[seq[byte]] {.gcsafe.} =
        return proc(i: Source[seq[byte]]) {.async.} =
          check: (await i()) == "\3na\n".toBytes()
          await pushable.close()

      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection, proto: string):
        Future[void] {.async, gcsafe.} = discard
      protocol.handler = testHandler
      ms.addHandler(TestProtoString, protocol)

      let conn = Connection.init(pushable)
      asyncCheck ms.handle(conn) # asyncCheck is fine here, because `handle` doesn't exit on `na`

      await pushable.push("/invalid/proto".toBytes())

    waitFor(test())

  test "e2e - handle":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection, proto: string):
        Future[void] {.async, gcsafe.} =
        var pushable = BytePushable.init()
        var lp = LenPrefixed.init()
        var sink = pipe(pushable, lp.encoder, conn)

        check: proto == TestProtoString
        await pushable.push(TestString.toBytes())
        await pushable.close()

        await sink

      protocol.handler = testHandler
      var msListen = MultistreamSelect.init()
      msListen.addHandler(TestProtoString, protocol)

      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)

      let transport1: TcpTransport = newTransport(TcpTransport)
      let transportFut = await transport1.listen(ma, connHandler)

      let msDial = MultistreamSelect.init()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      check:
        await msDial.select(conn, TestProtoString)

      var lp = LenPrefixed.init()
      var source = pipe(conn, lp.decoder)

      let hello = string.fromBytes(await source())
      check: hello == TestString

      await conn.close()
      await transport1.close()
      await transportFut

    waitFor(test())

  test "e2e - ls":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      var msListen = MultistreamSelect.init()
      var protocol: LPProtocol = new LPProtocol
      protocol.handler = proc(conn: Connection,
                              proto: string) {.async, gcsafe.} =
        check: false

      proc testHandler(conn: Connection,
                       proto: string):
                       Future[void] {.async.} = discard

      protocol.handler = testHandler
      msListen.addHandler("/test/proto1/1.0.0", protocol)
      msListen.addHandler("/test/proto2/1.0.0", protocol)

      let transport1 = newTransport(TcpTransport)
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)

      var transportFut = await transport1.listen(ma, connHandler)
      let msDial = MultistreamSelect.init()
      let transport2 = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      check:
        (await msDial.list(conn)) == @["/test/proto1/1.0.0", "/test/proto2/1.0.0"]

      await conn.close()
      await transport1.close()
      await transportFut

    waitFor(test())

  test "e2e - select one from a list with unsupported protos":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
      let lp = LenPrefixed.init()

      var protocol: LPProtocol = new LPProtocol
      proc testHandler(conn: Connection,
                       proto: string):
                       Future[void] {.async, gcsafe.} =
        check:
          proto == "/test/proto/1.0.0"

        var pushable = BytePushable.init()
        var sink = pipe(pushable,
                        lp.encoder(),
                        conn)

        await pushable.push(TestString.toBytes())
        await pushable.close()
        await sink

      protocol.handler = testHandler

      var msListen = MultistreamSelect.init()
      msListen.addHandler("/test/proto/1.0.0", protocol)

      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        await msListen.handle(conn)

      let transport1: TcpTransport = newTransport(TcpTransport)
      var transportFut = await transport1.listen(ma, connHandler)

      let msDial = MultistreamSelect.init()
      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)

      check:
        (await msDial.select(conn,
                             @["/test/proto/1.0.0",
                             "/test/no/proto/1.0.0"])) == "/test/proto/1.0.0"

      var source = pipe(conn, lp.decoder())
      check:
        (await source()) == TestString.toBytes()

      await conn.close()
      await transport1.close()
      await transportFut

    waitFor(test())

  # test "e2e - select one with both valid":
  #   proc endToEnd(): Future[bool] {.async.} =
  #     let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

  #     var protocol: LPProtocol = new LPProtocol
  #     proc testHandler(conn: Connection,
  #                      proto: string):
  #                      Future[void] {.async, gcsafe.} =
  #       await conn.writeLp(&"Hello from {proto}!")
  #       await conn.close()

  #     protocol.handler = testHandler
  #     let msListen = newMultistream()
  #     msListen.addHandler("/test/proto1/1.0.0", protocol)
  #     msListen.addHandler("/test/proto2/1.0.0", protocol)

  #     proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
  #       await msListen.handle(conn)

  #     let transport1: TcpTransport = newTransport(TcpTransport)
  #     asyncCheck transport1.listen(ma, connHandler)

  #     let msDial = newMultistream()
  #     let transport2: TcpTransport = newTransport(TcpTransport)
  #     let conn = await transport2.dial(transport1.ma)

  #     check (await msDial.select(conn, @["/test/proto2/1.0.0", "/test/proto1/1.0.0"])) == "/test/proto2/1.0.0"

  #     result = cast[string](await conn.readLp()) == "Hello from /test/proto2/1.0.0!"
  #     await conn.close()

  #   check:
  #     waitFor(endToEnd()) == true

import unittest
import chronos
import transports/[transport, tcptransport],
       streams/[stream, connection, utils],
       multiaddress,
       wire

when defined(nimHasUsed): {.used.}

const
  TestBytes: seq[byte] = @[72.byte, 101.byte,
                           108.byte, 108.byte,
                           111.byte, 33.byte]

suite "TCP transport":
  test "test listener handle write":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
      let finished = Future[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        iterator source(): Future[seq[byte]] {.closure.} =
          yield TestBytes.toFuture

        var sink = conn.sink()
        await source.sink()
        await conn.close()
        finished.complete()

      let transport: TcpTransport = newTransport(TcpTransport)
      var transportFut = await transport.listen(ma, connHandler)
      let streamTransport: StreamTransport = await transport.ma.connect()
      let msg = await streamTransport.read(TestBytes.len)

      await finished
      await transport.close()
      await streamTransport.closeWait()
      await transportFut

      check:
        msg == TestBytes

    waitFor(test())

  test "test listener handle read":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")
      var finished = newFuture[void]()
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        var msg: seq[byte]
        msg = await conn.source()() # read from the source

        check:
          msg == TestBytes

        finished.complete()

      let transport = newTransport(TcpTransport)
      let transportFut = await transport.listen(ma, connHandler)
      let streamTransport = await connect(transport.ma)
      let sent = await streamTransport.write(TestBytes, TestBytes.len)

      check: sent == 6

      await finished
      await transport.close()
      await streamTransport.closeWait()
      await transportFut

    waitFor(test())

  test "test dialer handle write":
    proc test(address: TransportAddress) {.async.} =
      let finished = newFuture[void]()
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async, gcsafe.} =
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("Hello!")

        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
        finished.complete()

      var server = createStreamServer(address, serveClient)
      server.start()

      let ma: MultiAddress = MultiAddress.init(server.sock.getLocalAddress())
      let transport: TcpTransport = newTransport(TcpTransport)
      let conn = await transport.dial(ma)
      let source  = conn.source()
      var msg: seq[byte]
      for item in source:
        msg = await item
        if msg.len > 0: break

      check: msg == TestBytes

      await finished
      await conn.close()
      server.stop()
      server.close()
      await server.join()

    waitFor(test(initTAddress("0.0.0.0:0")))

  test "test dialer handle write":
    proc test(address: TransportAddress) {.async, gcsafe.} =

      let finished = Future[void]()
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async, gcsafe.} =
        var rstream = newAsyncStreamReader(transp)
        let msg = await rstream.read(TestBytes.len)
        check: msg == TestBytes

        await rstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

        finished.complete()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()

      let ma: MultiAddress = MultiAddress.init(server.sock.getLocalAddress())
      let transport: TcpTransport = newTransport(TcpTransport)
      let conn = await transport.dial(ma)

      iterator source(): Future[seq[byte]] {.closure.} =
        yield TestBytes.toFuture

      let sink = conn.sink()
      await source.sink()
      await finished

      server.stop()
      server.close()
      await server.join()

    waitFor(test(initTAddress("0.0.0.0:0")))

  test "e2e handle write":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      let finished = newFuture[void]()
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        iterator source(): Future[seq[byte]] {.closure.} =
          yield TestBytes.toFuture

        let sink = conn.sink()
        await source.sink()

        finished.complete()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let transportFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)
      let msg = await conn.source()()

      check: msg == TestBytes

      await finished
      await transport1.close()
      await transport2.close()
      await transportFut

    waitFor(test())

  test "e2e handle read":
    proc test() {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0")

      let finished = newFuture[void]()
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        let msg = await conn.source()()
        check: msg == TestBytes

        finished.complete()

      let transport1: TcpTransport = newTransport(TcpTransport)
      let transportFut = await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(transport1.ma)
      iterator source(): Future[seq[byte]] {.closure.} =
        yield TestBytes.toFuture

      var sink = conn.sink()
      await source.sink()

      await finished
      await transport1.close()
      await transportFut

    waitFor(test())

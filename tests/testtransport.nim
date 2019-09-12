import unittest
import chronos
import ../libp2p/connection, 
       ../libp2p/transports/transport, 
       ../libp2p/transports/tcptransport,
       ../libp2p/multiaddress, 
       ../libp2p/wire

suite "TCP transport":
  test "test listener: handle write":
    proc testListener(): Future[bool] {.async, gcsafe.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53335")
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        result = conn.write(cstring("Hello!"), 6)

      let transport: TcpTransport = newTransport(TcpTransport)
      asyncCheck await transport.listen(ma, connHandler)
      let streamTransport: StreamTransport = await connect(ma)
      let msg = await streamTransport.read(6)
      await transport.close()
      await streamTransport.closeWait()

      result = cast[string](msg) == "Hello!"

    check:
      waitFor(testListener()) == true

  test "test listener: handle read":
    proc testListener(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53336")
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        let msg = await conn.read(6)
        check cast[string](msg) == "Hello!"

      let transport: TcpTransport = newTransport(TcpTransport)
      asyncCheck await transport.listen(ma, connHandler)
      let streamTransport: StreamTransport = await connect(ma)
      let sent = await streamTransport.write("Hello!", 6)
      result = sent == 6

    check:
      waitFor(testListener()) == true

  test "test dialer: handle write":
    proc testDialer(address: TransportAddress): Future[bool] {.async.} =
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async, gcsafe.} =
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("Hello!")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()

      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53337")
      let transport: TcpTransport = newTransport(TcpTransport)
      let conn = await transport.dial(ma)
      let msg = await conn.read(6)
      result = cast[string](msg) == "Hello!"

      server.stop()
      server.close()
      await server.join()
    check waitFor(testDialer(initTAddress("127.0.0.1:53337"))) == true

  test "test dialer: handle write":
    proc testDialer(address: TransportAddress): Future[bool] {.async, gcsafe.} =
      proc serveClient(server: StreamServer,
                        transp: StreamTransport) {.async, gcsafe.} =
        var rstream = newAsyncStreamReader(transp)
        let msg = await rstream.read(6)
        check cast[string](msg) == "Hello!"

        await rstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()

      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53337")
      let transport: TcpTransport = newTransport(TcpTransport)
      let conn = await transport.dial(ma)
      await conn.write(cstring("Hello!"), 6)
      result = true

      server.stop()
      server.close()
      await server.join()
    check waitFor(testDialer(initTAddress("127.0.0.1:53337"))) == true

  test "e2e: handle write":
    proc testListenerDialer(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53339")
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        result = conn.write(cstring("Hello!"), 6)

      let transport1: TcpTransport = newTransport(TcpTransport)
      asyncCheck await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)
      let msg = await conn.read(6)
      await transport1.close()

      result = cast[string](msg) == "Hello!"

    check:
      waitFor(testListenerDialer()) == true

  test "e2e: handle read":
    proc testListenerDialer(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/127.0.0.1/tcp/53340")
      proc connHandler(conn: Connection): Future[void] {.async, gcsafe.} =
        let msg = await conn.read(6)
        check cast[string](msg) == "Hello!"

      let transport1: TcpTransport = newTransport(TcpTransport)
      asyncCheck await transport1.listen(ma, connHandler)

      let transport2: TcpTransport = newTransport(TcpTransport)
      let conn = await transport2.dial(ma)
      await conn.write(cstring("Hello!"), 6)
      await transport1.close()
      result = true

    check:
      waitFor(testListenerDialer()) == true

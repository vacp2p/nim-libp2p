{.used.}

import unittest
import chronos, stew/byteutils
import ../libp2p/[stream/connection,
                  transports/transport,
                  transports/tcptransport,
                  multiaddress,
                  wire]
import ./helpers

suite "TCP transport":
  teardown:
    for tracker in testTrackers():
      # echo tracker.dump()
      check tracker.isLeaked() == false

  test "test listener: handle write":
    proc testListener(): Future[bool] {.async, gcsafe.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      let handlerWait = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        await conn.write(cstring("Hello!"), 6)
        await conn.close()
        handlerWait.complete()

      let transport: TcpTransport = TcpTransport.init()

      asyncCheck transport.listen(ma, connHandler)

      let streamTransport = await connect(transport.ma)

      let msg = await streamTransport.read(6)

      await handlerWait.wait(5000.millis) # when no issues will not wait that long!
      await streamTransport.closeWait()
      await transport.close()

      result = string.fromBytes(msg) == "Hello!"

    check:
      waitFor(testListener()) == true

  test "test listener: handle read":
    proc testListener(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      let handlerWait = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        var msg = newSeq[byte](6)
        await conn.readExactly(addr msg[0], 6)
        check string.fromBytes(msg) == "Hello!"
        await conn.close()
        handlerWait.complete()

      let transport: TcpTransport = TcpTransport.init()
      asyncCheck await transport.listen(ma, connHandler)
      let streamTransport: StreamTransport = await connect(transport.ma)
      let sent = await streamTransport.write("Hello!", 6)

      await handlerWait.wait(5000.millis) # when no issues will not wait that long!
      await streamTransport.closeWait()
      await transport.close()

      result = sent == 6

    check:
      waitFor(testListener()) == true

  test "test dialer: handle write":
    proc testDialer(address: TransportAddress): Future[bool] {.async.} =
      let handlerWait = newFuture[void]()
      proc serveClient(server: StreamServer,
                       transp: StreamTransport) {.async, gcsafe.} =
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write("Hello!")
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
        handlerWait.complete()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()

      let ma: MultiAddress = MultiAddress.init(server.sock.getLocalAddress()).tryGet()
      let transport: TcpTransport = TcpTransport.init()
      let conn = await transport.dial(ma)
      var msg = newSeq[byte](6)
      await conn.readExactly(addr msg[0], 6)
      result = string.fromBytes(msg) == "Hello!"

      await handlerWait.wait(5000.millis) # when no issues will not wait that long!

      await conn.close()
      await transport.close()

      server.stop()
      server.close()
      await server.join()

    check:
      waitFor(testDialer(initTAddress("0.0.0.0:0"))) == true

  test "test dialer: handle write":
    proc testDialer(address: TransportAddress): Future[bool] {.async, gcsafe.} =
      let handlerWait = newFuture[void]()
      proc serveClient(server: StreamServer,
                        transp: StreamTransport) {.async, gcsafe.} =
        var rstream = newAsyncStreamReader(transp)
        let msg = await rstream.read(6)
        check string.fromBytes(msg) == "Hello!"

        await rstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
        handlerWait.complete()

      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()

      let ma: MultiAddress = MultiAddress.init(server.sock.getLocalAddress()).tryGet()
      let transport: TcpTransport = TcpTransport.init()
      let conn = await transport.dial(ma)
      await conn.write(cstring("Hello!"), 6)
      result = true

      await handlerWait.wait(5000.millis) # when no issues will not wait that long!

      await conn.close()
      await transport.close()

      server.stop()
      server.close()
      await server.join()
    check:
      waitFor(testDialer(initTAddress("0.0.0.0:0"))) == true

  test "e2e: handle write":
    proc testListenerDialer(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      let handlerWait = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        await conn.write(cstring("Hello!"), 6)
        await conn.close()
        handlerWait.complete()

      let transport1: TcpTransport = TcpTransport.init()
      asyncCheck transport1.listen(ma, connHandler)

      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)
      var msg = newSeq[byte](6)
      await conn.readExactly(addr msg[0], 6)

      await handlerWait.wait(5000.millis) # when no issues will not wait that long!

      await conn.close()
      await transport2.close()
      await transport1.close()

      result = string.fromBytes(msg) == "Hello!"

    check:
      waitFor(testListenerDialer()) == true

  test "e2e: handle read":
    proc testListenerDialer(): Future[bool] {.async.} =
      let ma: MultiAddress = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      let handlerWait = newFuture[void]()
      proc connHandler(conn: Connection) {.async, gcsafe.} =
        var msg = newSeq[byte](6)
        await conn.readExactly(addr msg[0], 6)
        check string.fromBytes(msg) == "Hello!"
        await conn.close()
        handlerWait.complete()

      let transport1: TcpTransport = TcpTransport.init()
      asyncCheck transport1.listen(ma, connHandler)

      let transport2: TcpTransport = TcpTransport.init()
      let conn = await transport2.dial(transport1.ma)
      await conn.write(cstring("Hello!"), 6)

      await handlerWait.wait(5000.millis) # when no issues will not wait that long!

      await conn.close()
      await transport2.close()
      await transport1.close()
      result = true

    check:
      waitFor(testListenerDialer()) == true

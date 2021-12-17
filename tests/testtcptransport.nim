{.used.}

import sequtils
import chronos, stew/byteutils
import ../libp2p/[stream/connection,
                  transports/transport,
                  transports/tcptransport,
                  upgrademngrs/upgrade,
                  multiaddress,
                  errors,
                  wire]

import ./helpers, ./commontransport

suite "TCP transport":
  teardown:
    checkTrackers()

  asyncTest "test listener: handle write":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let transport: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    asyncSpawn transport.start(ma)

    proc acceptHandler() {.async, gcsafe.} =
      let conn = await transport.accept()
      await conn.write("Hello!")
      await conn.close()

    let handlerWait = acceptHandler()

    let streamTransport = await connect(transport.addrs[0])

    let msg = await streamTransport.read(6)

    await handlerWait.wait(1.seconds) # when no issues will not wait that long!
    await streamTransport.closeWait()
    await transport.stop()
    check string.fromBytes(msg) == "Hello!"

  asyncTest "test listener: handle read":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]

    let transport: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    asyncSpawn transport.start(ma)

    proc acceptHandler() {.async, gcsafe.} =
      var msg = newSeq[byte](6)
      let conn = await transport.accept()
      await conn.readExactly(addr msg[0], 6)
      check string.fromBytes(msg) == "Hello!"
      await conn.close()

    let handlerWait = acceptHandler()
    let streamTransport: StreamTransport = await connect(transport.addrs[0])
    let sent = await streamTransport.write("Hello!")

    await handlerWait.wait(1.seconds) # when no issues will not wait that long!
    await streamTransport.closeWait()
    await transport.stop()

    check sent == 6

  asyncTest "test dialer: handle write":
    let address = initTAddress("0.0.0.0:0")
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
    let transport: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    let conn = await transport.dial(ma)
    var msg = newSeq[byte](6)
    await conn.readExactly(addr msg[0], 6)
    check string.fromBytes(msg) == "Hello!"

    await handlerWait.wait(1.seconds) # when no issues will not wait that long!

    await conn.close()
    await transport.stop()

    server.stop()
    server.close()
    await server.join()

  asyncTest "test dialer: handle write":
    let address = initTAddress("0.0.0.0:0")
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
    let transport: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    let conn = await transport.dial(ma)
    await conn.write("Hello!")

    await handlerWait.wait(1.seconds) # when no issues will not wait that long!

    await conn.close()
    await transport.stop()

    server.stop()
    server.close()
    await server.join()

  asyncTest "pessimistic: default listenError callback returns TransportListenError":
    let
      transport = TcpTransport.new(upgrade = Upgrade())

    check not transport.listenError.isNil

    let
      exc = newException(CatchableError, "test")
      ma = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      listenErrResult = await transport.listenError(ma, exc)

    check:
      not listenErrResult.isNil
      listenErrResult is (ref TransportListenError)

    await transport.stop()

  asyncTest "listenError callback assignable and callable":
    let
      failListenErr = proc(
          maErr: MultiAddress,
          exc: ref CatchableError): Future[ref TransportListenError] {.async.} =
        fail()
      transport = TcpTransport.new(
        upgrade = Upgrade(),
        listenError = failListenErr)
      ma = Multiaddress.init("/ip4/0.0.0.0/tcp/0").tryGet()
      catchableError = newException(CatchableError, "test1")
      transportListenError = newTransportListenError(ma, catchableError)

    transport.listenError = proc(
        maErr: MultiAddress,
        exc: ref CatchableError): Future[ref TransportListenError] {.async.} =

      check:
        exc == catchableError
        maErr == ma

      return transportListenError

    let listenErrResult = await transport.listenError(ma, catchableError)

    check:
      listenErrResult == transportListenError

    await transport.stop()

  asyncTest "pessimistic: default listenError re-raises exception":
    let
      # use a bad MultiAddress to throw an error during transport.start
      ma = Multiaddress.init("/ip4/1.0.0.0/tcp/0").tryGet()

      transport = TcpTransport.new(upgrade = Upgrade())

    expect TransportListenError:
      await transport.start(@[ma])

    await transport.stop()

  asyncTest "pessimistic: overridden listenError re-raises exception":
    var transportListenErr: ref TransportListenError

    let
      # use a bad MultiAddress to throw an error during transport.start
      ma = Multiaddress.init("/ip4/1.0.0.0/tcp/0").tryGet()
      listenError = proc(
          maErr: MultiAddress,
          exc: ref CatchableError): Future[ref TransportListenError] {.async.} =

        transportListenErr = newTransportListenError(maErr, exc)
        check maErr == ma
        return transportListenErr

      transport = TcpTransport.new(
        upgrade = Upgrade(),
        listenError = listenError)

    try:
      await transport.start(@[ma])
      fail()
    except TransportListenError as e:
      check e == transportListenErr

    await transport.stop()

  asyncTest "optimistic: overridden listenError does not re-raise exception":
    var transportListenErr: ref TransportListenError

    let
      # use a bad MultiAddress to throw an error during transport.start
      ma = Multiaddress.init("/ip4/1.0.0.0/tcp/0").tryGet()
      listenError = proc(
          maErr: MultiAddress,
          exc: ref CatchableError): Future[ref TransportListenError] {.async.} =

        check maErr == ma
        return nil

      transport = TcpTransport.new(
        upgrade = Upgrade(),
        listenError = listenError)

    try:
      await transport.start(@[ma])
    except TransportListenError as e:
      fail()

    await transport.stop()

  asyncTest "handles correct tcp addresses":
    let
      transport = TcpTransport.new(upgrade = Upgrade())
      maTcp1 = Multiaddress.init("/ip4/0.0.0.0/tcp/1").tryGet()
      maUdp = Multiaddress.init("/ip4/0.0.0.0/udp/0").tryGet()
      maTcp2 = Multiaddress.init("/ip4/0.0.0.0/tcp/2").tryGet()
      maP2p = Multiaddress.init("/p2p-circuit").tryGet()

    check:
      transport.handles(maTcp1)
      transport.handles(maTcp2)
      not transport.handles(maUdp)
      not transport.handles(maP2p)

    await transport.stop()

  asyncTest "should raise Defect on start with no addresses":
    let transport = TcpTransport.new(upgrade = Upgrade())

    expect TransportDefect:
      await transport.start(@[])

    await transport.stop()

  commonTransportTest(
    "TcpTransport",
    proc (): Transport = TcpTransport.new(upgrade = Upgrade()),
    "/ip4/0.0.0.0/tcp/0")

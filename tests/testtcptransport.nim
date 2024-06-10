{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, stew/byteutils
import
  ../libp2p/[
    stream/connection,
    transports/transport,
    transports/tcptransport,
    upgrademngrs/upgrade,
    multiaddress,
    multicodec,
    errors,
    wire,
  ]

import ./helpers, ./commontransport

suite "TCP transport":
  teardown:
    checkTrackers()

  asyncTest "test listener: handle write":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let transport: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    asyncSpawn transport.start(ma)

    proc acceptHandler() {.async.} =
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

    proc acceptHandler() {.async.} =
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
    proc serveClient(server: StreamServer, transp: StreamTransport) {.async.} =
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
    proc serveClient(server: StreamServer, transp: StreamTransport) {.async.} =
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

  asyncTest "Starting with duplicate but zero ports addresses must NOT fail":
    let ma =
      @[
        MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
        MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet(),
      ]

    let transport: TcpTransport = TcpTransport.new(upgrade = Upgrade())

    await transport.start(ma)
    await transport.stop()

  asyncTest "Bind to listening port when not reachable":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let transport: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    await transport.start(ma)

    let ma2 = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let transport2: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    await transport2.start(ma2)

    let ma3 = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let transport3: TcpTransport = TcpTransport.new(upgrade = Upgrade())
    await transport3.start(ma3)

    let listeningPort = transport.addrs[0][multiCodec("tcp")].get()

    let conn = await transport.dial(transport2.addrs[0])
    let acceptedConn = await transport2.accept()
    let acceptedPort = acceptedConn.observedAddr.get()[multiCodec("tcp")].get()
    check listeningPort != acceptedPort

    transport.networkReachability = NetworkReachability.NotReachable

    let conn2 = await transport.dial(transport3.addrs[0])
    let acceptedConn2 = await transport3.accept()
    let acceptedPort2 = acceptedConn2.observedAddr.get()[multiCodec("tcp")].get()
    check listeningPort == acceptedPort2

    await allFutures(transport.stop(), transport2.stop(), transport3.stop())

  proc transProvider(): Transport =
    TcpTransport.new(upgrade = Upgrade())

  asyncTest "Custom timeout":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0").tryGet()]
    let transport: TcpTransport =
      TcpTransport.new(upgrade = Upgrade(), connectionsTimeout = 1.milliseconds)
    asyncSpawn transport.start(ma)

    proc acceptHandler() {.async.} =
      let conn = await transport.accept()
      await conn.join()

    let handlerWait = acceptHandler()

    let streamTransport = await connect(transport.addrs[0])
    await handlerWait.wait(1.seconds) # when no issues will not wait that long!
    await streamTransport.closeWait()
    await transport.stop()

  commonTransportTest(transProvider, "/ip4/0.0.0.0/tcp/0")

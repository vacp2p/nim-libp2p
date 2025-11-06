# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, stew/byteutils
import
  ../../libp2p/[
    stream/connection,
    transports/transport,
    transports/tcptransport,
    upgrademngrs/upgrade,
    multiaddress,
    multicodec,
    wire,
  ]
import ../tools/[unittest]
import ./utils

const message = "No Backdoors. No Masters. No Silence."

template tcpIPTestsSuite*(
    suiteName: string, provider: TransportProvider, address: string
) =
  block:
    let transportProvider = provider
    let serverListenAddr = @[MultiAddress.init(address).tryGet()]

    asyncTest suiteName & ":listener: handle write":
      let server = transportProvider()
      asyncSpawn server.start(serverListenAddr)

      proc serverHandler() {.async.} =
        let conn = await server.accept()
        await conn.write(message)
        await conn.close()

      let handlerFut = serverHandler()

      let conn = await connect(server.addrs[0])
      let receivedData = await conn.read(message.len)
      check string.fromBytes(receivedData) == message

      await handlerFut.wait(1.seconds)
      await conn.closeWait()
      await server.stop()

    asyncTest suiteName & ":listener: handle read":
      let server = transportProvider()
      asyncSpawn server.start(serverListenAddr)

      proc serverHandler() {.async.} =
        let conn = await server.accept()
        var msg = newSeq[byte](message.len)
        await conn.readExactly(addr msg[0], message.len)
        check string.fromBytes(msg) == message
        await conn.close()

      let handlerFut = serverHandler()

      let conn = await connect(server.addrs[0])
      let sentBytes = await conn.write(message)
      check sentBytes == message.len

      await handlerFut.wait(1.seconds)
      await conn.closeWait()
      await server.stop()

template miscellaneousTestsSuite*(provider: TransportProvider) =
  block:
    let transportProvider = provider
    asyncTest "dialer: handle write":
      let handlerFut = newFuture[void]()
      proc serverHandler(server: StreamServer, transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write(message)
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
        handlerFut.complete()

      let sa = initTAddress("0.0.0.0:0")
      var server = createStreamServer(sa, serverHandler, {ReuseAddr})
      server.start()

      let ma: MultiAddress = MultiAddress.init(server.sock.getLocalAddress()).tryGet()
      let client = transportProvider()
      let conn = await client.dial(ma)

      var msg = newSeq[byte](message.len)
      await conn.readExactly(addr msg[0], message.len)
      check string.fromBytes(msg) == message

      await handlerFut.wait(1.seconds)
      await conn.close()
      await client.stop()
      server.stop()
      server.close()
      await server.join()

    asyncTest "dialer: handle write":
      let handlerFut = newFuture[void]()
      proc serveClient(server: StreamServer, transp: StreamTransport) {.async.} =
        var rstream = newAsyncStreamReader(transp)
        let msg = await rstream.read(message.len)
        check string.fromBytes(msg) == message

        await rstream.closeWait()
        await transp.closeWait()
        server.stop()
        server.close()
        handlerFut.complete()

      let address = initTAddress("0.0.0.0:0")
      var server = createStreamServer(address, serveClient, {ReuseAddr})
      server.start()

      let ma: MultiAddress = MultiAddress.init(server.sock.getLocalAddress()).tryGet()
      let client = transportProvider()
      let conn = await client.dial(ma)
      await conn.write(message)

      await handlerFut.wait(1.seconds)
      await conn.close()
      await client.stop()
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

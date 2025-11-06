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

const
  message = "No Backdoors. No Masters. No Silence."
  zeroMultiaddressStrIP4 = "/ip4/0.0.0.0/tcp/0"
  zeroMultiaddressStrIP6 = "/ip6/::/tcp/0"
  zeroAddr = "0.0.0.0:0"

proc transportProvider(): Transport =
  TcpTransport.new(upgrade = Upgrade())

template tcpIPTests(suiteName: string, address: string) =
  block:
    let serverListenAddr = @[MultiAddress.init(address).tryGet()]

    asyncTest suiteName & ":listener: handle write":
      let server = transportProvider()
      await server.start(serverListenAddr)

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
      await server.start(serverListenAddr)

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

template tcpTests*() =
  block:
    let zeroMultiaddress = MultiAddress.init(zeroMultiaddressStrIP4).tryGet()

    tcpIPTests("ipv4", zeroMultiaddressStrIP4)
    tcpIPTests("ipv6", zeroMultiaddressStrIP6)

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

      let sa = initTAddress(zeroAddr)
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

      let address = initTAddress(zeroAddr)
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
      let transport = transportProvider()

      let ma = @[zeroMultiaddress, zeroMultiaddress]
      await transport.start(ma)
      await transport.stop()

    asyncTest "Bind to listening port when not reachable":
      let transport1 = transportProvider()
      await transport1.start(@[zeroMultiaddress])

      let transport2 = transportProvider()
      await transport2.start(@[zeroMultiaddress])

      let transport3 = transportProvider()
      await transport3.start(@[zeroMultiaddress])

      let listeningPortTransport1 = transport1.addrs[0][multiCodec("tcp")].get()

      let conn = await transport1.dial(transport2.addrs[0])
      let acceptedConn = await transport2.accept()
      let acceptedPort2 = acceptedConn.observedAddr.get()[multiCodec("tcp")].get()
      check listeningPortTransport1 != acceptedPort2

      transport1.networkReachability = NetworkReachability.NotReachable

      let conn2 = await transport1.dial(transport3.addrs[0])
      let acceptedConn3 = await transport3.accept()
      let acceptedPort3 = acceptedConn3.observedAddr.get()[multiCodec("tcp")].get()
      check listeningPortTransport1 == acceptedPort3

      await allFutures(transport1.stop(), transport2.stop(), transport3.stop())

    asyncTest "Custom timeout":
      let server: TcpTransport =
        TcpTransport.new(upgrade = Upgrade(), connectionsTimeout = 1.milliseconds)
      await server.start(@[zeroMultiaddress])

      proc serverHandler() {.async.} =
        let conn = await server.accept()
        await conn.join()

      let handlerFut = serverHandler()

      let streamTransport = await connect(server.addrs[0])
      await handlerFut.wait(1.seconds)
      await streamTransport.closeWait()
      await server.stop()

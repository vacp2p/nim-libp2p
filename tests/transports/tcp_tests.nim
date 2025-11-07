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
  zeroMAStrIP4 = "/ip4/0.0.0.0/tcp/0"
  zeroMAStrIP6 = "/ip6/::/tcp/0"
  zeroTAIP4 = "0.0.0.0:0"
  zeroTAIP6 = "[::]:0"

template tcpListenerIPTests(suiteName: string, listenMA: MultiAddress) =
  block:
    asyncTest suiteName & ":listener: handle write":
      let server = TcpTransport.new(upgrade = Upgrade())
      await server.start(@[listenMA])

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
      let server = TcpTransport.new(upgrade = Upgrade())
      await server.start(@[listenMA])

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

template tcpDialerIPTest(suiteName: string, listenTA: TransportAddress) =
  block:
    asyncTest suiteName & ":dialer: handle write":
      let handlerFut = newFuture[void]()
      proc serverHandler(server: StreamServer, transp: StreamTransport) {.async.} =
        var wstream = newAsyncStreamWriter(transp)
        await wstream.write(message)
        await wstream.finish()
        await wstream.closeWait()
        await transp.closeWait()
        handlerFut.complete()

      let server = createStreamServer(listenTA, serverHandler, {ReuseAddr})
      server.start()

      let ma = MultiAddress.init(server.sock.getLocalAddress()).tryGet()
      let client = TcpTransport.new(upgrade = Upgrade())
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

    asyncTest suiteName & ":dialer: handle write":
      let handlerFut = newFuture[void]()
      proc serverHandler(server: StreamServer, transp: StreamTransport) {.async.} =
        var rstream = newAsyncStreamReader(transp)
        let msg = await rstream.read(message.len)
        check string.fromBytes(msg) == message

        await rstream.closeWait()
        await transp.closeWait()
        handlerFut.complete()

      let server = createStreamServer(listenTA, serverHandler, {ReuseAddr})
      server.start()

      let ma = MultiAddress.init(server.sock.getLocalAddress()).tryGet()
      let client = TcpTransport.new(upgrade = Upgrade())
      let conn = await client.dial(ma)
      await conn.write(message)

      await handlerFut.wait(1.seconds)
      await conn.close()
      await client.stop()
      server.stop()
      server.close()
      await server.join()

template tcpTests*() =
  tcpListenerIPTests("ipv4", MultiAddress.init(zeroMAStrIP4).tryGet())
  tcpListenerIPTests("ipv6", MultiAddress.init(zeroMAStrIP6).tryGet())
  tcpDialerIPTest("ipv4", initTAddress(zeroTAIP4))
  tcpDialerIPTest("ipv6", initTAddress(zeroTAIP6))

  block:
    let listenMA = MultiAddress.init(zeroMAStrIP4).tryGet()

    asyncTest "starting with duplicate but zero ports addresses must NOT fail":
      let transport = TcpTransport.new(upgrade = Upgrade())

      await transport.start(@[listenMA, listenMA])
      await transport.stop()

    asyncTest "bind to listening port when not reachable":
      let transport1 = TcpTransport.new(upgrade = Upgrade())
      await transport1.start(@[listenMA])

      let transport2 = TcpTransport.new(upgrade = Upgrade())
      await transport2.start(@[listenMA])

      let transport3 = TcpTransport.new(upgrade = Upgrade())
      await transport3.start(@[listenMA])

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

    asyncTest "custom timeout":
      let server =
        TcpTransport.new(upgrade = Upgrade(), connectionsTimeout = 1.milliseconds)
      await server.start(@[listenMA])

      proc serverHandler() {.async.} =
        let conn = await server.accept()
        await conn.join()

      let handlerFut = serverHandler()

      let streamTransport = await connect(server.addrs[0])
      await handlerFut.wait(1.seconds)
      await streamTransport.closeWait()
      await server.stop()

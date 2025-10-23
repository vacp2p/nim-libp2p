{.used.}

import chronos, results, stew/byteutils
import
  ../../libp2p/
    [stream/connection, transports/transport, upgrademngrs/upgrade, multiaddress]

import ../helpers
import ./utils

template basicTransportTest*(
    provider: TransportBuilder, ma1: string, ma2: string = ""
) =
  block:
    let transportProvider = provider

    asyncTest "can handle local address":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let transport = transportProvider()
      await transport.start(ma)
      defer:
        await transport.stop()

      check transport.handles(transport.addrs[0])

    asyncTest "handle observedAddr":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      let client = transportProvider()

      let acceptFut = server.accept()
      let clientConn = await client.dial(server.addrs[0])
      let serverConn = await acceptFut

      defer:
        await allFutures(clientConn.close(), serverConn.close())
        await allFutures(client.stop(), server.stop())

      # Tor transport doesn't provide observedAddr for privacy reasons
      if not isTorTransport(server.addrs[0]):
        check:
          server.handles(clientConn.observedAddr.get())
          client.handles(serverConn.observedAddr.get())

      check:
        # skip IP check, only check transport and port
        serverConn.localAddr.get()[3] == server.addrs[0][3]
        serverConn.localAddr.get()[4] == server.addrs[0][4]

    asyncTest "handle dial cancellation":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      let client = transportProvider()
      defer:
        await allFutures(client.stop(), server.stop())

      let connFut = client.dial(server.addrs[0])
      await connFut.cancelAndWait()

      check connFut.cancelled

    asyncTest "handle accept cancellation":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      defer:
        await server.stop()

      let acceptFut = server.accept()
      await acceptFut.cancelAndWait()

      check acceptFut.cancelled

    asyncTest "stopping transport kills connections":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      let server = transportProvider()
      await server.start(ma)
      let client = transportProvider()

      let acceptFut = server.accept()
      let clientConn = await client.dial(server.addrs[0])
      let serverConn = await acceptFut

      await allFutures(client.stop(), server.stop())

      check:
        clientConn.closed()
        serverConn.closed()

    asyncTest "transport start/stop events":
      let ma = @[MultiAddress.init(ma1).tryGet()]
      let transport = transportProvider()

      await transport.start(ma)
      check await transport.onRunning.wait().withTimeout(1.seconds)

      await transport.stop()
      check await transport.onStop.wait().withTimeout(1.seconds)

template connectionTransportTest*(
    provider: TransportBuilder, ma1: string, ma2: string = ""
) =
  block:
    let transportProvider = provider

    asyncTest "handle write":
      let ma = @[MultiAddress.init(ma1).tryGet()]
      const message = "Hello!"

      proc serverHandler(server: Transport) {.async.} =
        let conn = await server.accept()
        defer:
          await conn.close()

        await conn.write(message)

      proc runClient(server: Transport) {.async.} =
        let client = transportProvider()
        let conn = await client.dial(server.addrs[0])
        defer:
          await conn.close()
          await client.stop()

        var buffer = newSeq[byte](message.len)
        await conn.readExactly(addr buffer[0], message.len)

        check string.fromBytes(buffer) == message

      let server = transportProvider()
      await server.start(ma)
      let serverFut = serverHandler(server)

      await runClient(server)
      await serverFut
      await server.stop()

    asyncTest "handle read":
      let ma = @[MultiAddress.init(ma1).tryGet()]
      const message = "Hello!"

      proc serverHandler(server: Transport) {.async.} =
        let conn = await server.accept()
        defer:
          await conn.close()

        var buffer = newSeq[byte](message.len)
        await conn.readExactly(addr buffer[0], message.len)

        check string.fromBytes(buffer) == message

      proc runClient(server: Transport) {.async.} =
        let client = transportProvider()
        let conn = await client.dial(server.addrs[0])
        defer:
          await conn.close()
          await client.stop()

        await conn.write(message)

      let server = transportProvider()
      await server.start(ma)
      let serverFut = serverHandler(server)

      await runClient(server)
      await serverFut
      await server.stop()

    asyncTest "e2e should allow multiple local addresses":
      when defined(windows):
        # this randomly locks the Windows CI job
        skip()
        return

      let addrs =
        @[
          MultiAddress.init(ma1).tryGet(),
          MultiAddress.init(if ma2 == "": ma1 else: ma2).tryGet(),
        ]
      const message = "Hello!"

      proc serverHandler(server: Transport) {.async.} =
        while true:
          let conn = await server.accept()
          await conn.write(newSeq[byte](0))
          await conn.write(message)
          await conn.close()

      proc runClient(server: Transport) {.async.} =
        let client = transportProvider()
        defer:
          await client.stop()

        check:
          server.addrs.len == 2
          server.addrs[0] != server.addrs[1]

        proc dialAndVerify(ma: MultiAddress) {.async.} =
          let conn = await client.dial(ma)
          defer:
            await conn.close()

          var buffer = newSeq[byte](message.len)
          await conn.readExactly(addr buffer[0], message.len)

          check string.fromBytes(buffer) == message

        # Dial the same server multiple time in a row
        await dialAndVerify(server.addrs[0])
        await dialAndVerify(server.addrs[0])
        await dialAndVerify(server.addrs[0])

        # Dial the same server on different addresses
        await dialAndVerify(server.addrs[1])
        await dialAndVerify(server.addrs[0])
        await dialAndVerify(server.addrs[1])

        # Cancel a dial
        # TODO add back once chronos fixes cancellation
        # let
        #   dial1 = client.dial(server.addrs[1])
        #   dial2 = client.dial(server.addrs[0])
        # await dial1.cancelAndWait()
        # await dial2.cancelAndWait()

      let server = transportProvider()
      await server.start(addrs)
      let serverFut = serverHandler(server)

      await runClient(server)
      await serverFut.cancelAndWait()
      await server.stop()

    asyncTest "read or write on closed connection":
      let ma = @[MultiAddress.init(ma1).tryGet()]

      proc serverHandler(server: Transport) {.async.} =
        let conn = await server.accept()
        await conn.close()

      proc runClient(server: Transport) {.async.} =
        let client = transportProvider()
        let conn = await client.dial(server.addrs[0])
        defer:
          await conn.close()
          await client.stop()

        var buffer = newSeq[byte](1)
        expect LPStreamEOFError:
          await conn.readExactly(addr buffer[0], 1)

        if isWsTransport(server.addrs[0]):
          # WS throws on write after EOF
          expect LPStreamEOFError:
            await conn.write(buffer)
        else:
          # TCP and TOR don't throw on write after EOF
          await conn.write(buffer)

      let server = transportProvider()
      await server.start(ma)
      let serverFut = serverHandler(server)

      await runClient(server)
      await serverFut
      await server.stop()

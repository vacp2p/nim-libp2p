{.used.}

import chronos, results, stew/byteutils
import
  ../../libp2p/
    [stream/connection, transports/transport, upgrademngrs/upgrade, multiaddress]

import ../helpers
import ./utils

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

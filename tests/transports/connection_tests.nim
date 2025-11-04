# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, results, stew/byteutils
import
  ../../libp2p/
    [stream/connection, transports/transport, upgrademngrs/upgrade, multiaddress]
import ../tools/[unittest]
import ./utils

template connectionTransportTest*(
    provider: TransportBuilder, ma1: string, ma2: string = ""
) =
  block:
    let transportProvider = provider
    const message =
      "Transparent, immutable records, as we will see, are critical to good governance"

    asyncTest "handle write":
      let ma = @[MultiAddress.init(ma1).tryGet()]

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

    asyncTest "should allow multiple local addresses":
      let addrs =
        @[
          MultiAddress.init(ma1).tryGet(),
          MultiAddress.init(if ma2 == "": ma1 else: ma2).tryGet(),
        ]

      proc serverHandler(server: Transport) {.async.} =
        while true:
          let conn = await server.accept()
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

        # TODO(nim-libp2p#1788): Unify behaviour between transports
        if isWsTransport(server.addrs[0]):
          # WS throws on write after EOF
          expect LPStreamEOFError:
            await conn.write(buffer)
        else:
          when defined(windows):
            if isTorTransport(server.addrs[0]):
              # TOR on Windows throws on write after EOF
              expect LPStreamEOFError:
                await conn.write(buffer)
            else:
              # TCP on Windows doesn't throw on write after EOF
              await conn.write(buffer)
          else:
            # TCP and TOR on non-Windows don't throw on write after EOF
            await conn.write(buffer)

      let server = transportProvider()
      await server.start(ma)
      let serverFut = serverHandler(server)

      await runClient(server)
      await serverFut
      await server.stop()

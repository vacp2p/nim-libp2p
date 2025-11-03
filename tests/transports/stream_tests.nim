# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, stew/byteutils
import ../../libp2p/[stream/connection, transports/transport, muxers/muxer]
import ../tools/[stream]
import ./utils

template streamTransportTest*(
    transportProvider: TransportProvider,
    address: string,
    streamProvider: StreamProvider,
) =
  const serverMessage =
    "Privacy is necessary for an open society in the electronic age."
  const clientMessage = "We can be decentralised yet cooperative."

  asyncTest "transport e2e":
    let ma = @[MultiAddress.init(address).tryGet()]

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noException(stream):
        var buffer: array[clientMessage.len, byte]
        await stream.readExactly(addr buffer, clientMessage.len)
        check string.fromBytes(buffer) == clientMessage

        await stream.write(serverMessage)

    proc clientStreamHandler(stream: Connection) {.async.} =
      await stream.write(clientMessage)

      var buffer: array[serverMessage.len, byte]
      await stream.readExactly(addr buffer, serverMessage.len)
      check string.fromBytes(buffer) == serverMessage

    await runSingleStreamScenario(
      ma, transportProvider, streamProvider, serverStreamHandler, clientStreamHandler
    )

  asyncTest "read/write Lp":
    let ma = @[MultiAddress.init(address).tryGet()]

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noException(stream):
        check (await stream.readLp(100)) == fromHex("1234")
        await stream.writeLp(fromHex("5678"))

    proc clientStreamHandler(stream: Connection) {.async.} =
      await stream.writeLp(fromHex("1234"))
      check (await stream.readLp(100)) == fromHex("5678")

    await runSingleStreamScenario(
      ma, transportProvider, streamProvider, serverStreamHandler, clientStreamHandler
    )

  asyncTest "EOF handling - first readOnce at EOF + repeated reads":
    let ma = @[MultiAddress.init(address).tryGet()]

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noException(stream):
        await stream.write(serverMessage)

    proc clientStreamHandler(stream: Connection) {.async.} =
      var buffer: array[serverMessage.len, byte]
      await stream.readExactly(addr buffer, serverMessage.len)
      check string.fromBytes(buffer) == serverMessage

      # First readOnce after EOF
      # nim-libp2p#1833 Transports: Inconsistent EOF behavior between QUIC and Mplex: first readOnce after EOF
      if (isQuicTransport(ma[0])):
        expect LPStreamEOFError:
          discard await stream.readOnce(addr buffer, 1)
      else:
        let bytesRead = await stream.readOnce(addr buffer, 1)
        check bytesRead == 0

      # Attempting second readOnce at EOF
      # nim-libp2p#1834 Transports: Inconsistent EOF behavior between QUIC and Mplex: consecutive readOnce after EOF
      if (isQuicTransport(ma[0])):
        expect LPStreamEOFError:
          discard await stream.readOnce(addr buffer, 1)
      else:
        expect LPStreamRemoteClosedError:
          discard await stream.readOnce(addr buffer, 1)

      # Attempting readExactly at EOF
      if (isQuicTransport(ma[0])):
        expect LPStreamEOFError:
          await stream.readExactly(addr buffer, 1)
      else:
        expect LPStreamRemoteClosedError:
          await stream.readExactly(addr buffer, 1)

    await runSingleStreamScenario(
      ma, transportProvider, streamProvider, serverStreamHandler, clientStreamHandler
    )

  asyncTest "client writes after EOF":
    let ma = @[MultiAddress.init(address).tryGet()]
    var serverMuxerTask: Future[void]

    proc serverHandler(server: Transport) {.async.} =
      let conn = await server.accept()
      let muxer = streamProvider(server, conn)
      muxer.streamHandler = proc(stream: Connection) {.async: (raises: []).} =
        noException(stream):
          # Custom pattern: closes muxer/connection inside the stream handler to force immediate shutdown.
          # Using serverHandlerSingleStream would deadlock: client waits for server task,
          # but muxer.handle() blocks reading messages until client closes its connection.
          await stream.write(serverMessage)
          await muxer.close()
          await conn.close()
      serverMuxerTask = muxer.handle()

    proc clientStreamHandler(stream: Connection) {.async.} =
      var buffer: array[serverMessage.len, byte]
      await stream.readExactly(addr buffer, serverMessage.len)
      check string.fromBytes(buffer) == serverMessage
      await serverMuxerTask

      if isQuicTransport(ma[0]):
        expect LPStreamError:
          await stream.write(clientMessage)
      else:
        expect LPStreamEOFError:
          await stream.write(clientMessage)

    let server = transportProvider()
    await server.start(ma)
    let serverTask = serverHandler(server)

    await clientRunSingleStream(
      server, transportProvider, streamProvider, clientStreamHandler
    )
    await serverTask
    await server.stop()

  asyncTest "incomplete read":
    let ma = @[MultiAddress.init(address).tryGet()]

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noException(stream):
        await stream.write(serverMessage)

    proc clientStreamHandler(stream: Connection) {.async.} =
      var buffer: array[2 * serverMessage.len, byte]

      if (isQuicTransport(ma[0])):
        expect LPStreamEOFError:
          await stream.readExactly(addr buffer, 2 * serverMessage.len)
      else:
        expect LPStreamIncompleteError:
          await stream.readExactly(addr buffer, 2 * serverMessage.len)

      # Verify that partial data was read before EOF
      check string.fromBytes(buffer[0 ..< serverMessage.len]) == serverMessage

    await runSingleStreamScenario(
      ma, transportProvider, streamProvider, serverStreamHandler, clientStreamHandler
    )

  asyncTest "server closeWrite - client can still write":
    let ma = @[MultiAddress.init(address).tryGet()]

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noException(stream):
        # Server sends data and closes its write side
        await stream.write(serverMessage)
        await stream.closeWrite()

        # Server should still be able to read from client
        var buffer: array[clientMessage.len, byte]
        await stream.readExactly(addr buffer, clientMessage.len)
        check string.fromBytes(buffer) == clientMessage

    proc clientStreamHandler(stream: Connection) {.async.} =
      # Client reads server data
      var buffer: array[serverMessage.len, byte]
      await stream.readExactly(addr buffer, serverMessage.len)
      check string.fromBytes(buffer) == serverMessage

      # Server has closed write side, so further reads should EOF
      if (isQuicTransport(ma[0])):
        expect LPStreamEOFError:
          discard await stream.readOnce(addr buffer, 1)
      else:
        # TCP/Mplex: First readOnce after closeWrite returns 0
        let bytesRead = await stream.readOnce(addr buffer, 1)
        check bytesRead == 0

      # Client should still be able to write back to server
      await stream.write(clientMessage)

    await runSingleStreamScenario(
      ma, transportProvider, streamProvider, serverStreamHandler, clientStreamHandler
    )

  asyncTest "stream caching with multiple partial reads":
    let ma = @[MultiAddress.init(address).tryGet()]
    const messageSize = 2048
    const chunkSize = 256
    let message = newData(messageSize)

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noException(stream):
        await stream.write(message)

    proc clientStreamHandler(stream: Connection) {.async.} =
      let receivedData = await readStreamByChunkTillEOF(stream, chunkSize, messageSize)
      check receivedData == message

    await runSingleStreamScenario(
      ma, transportProvider, streamProvider, serverStreamHandler, clientStreamHandler
    )

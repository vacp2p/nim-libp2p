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
      noExceptionWithStreamClose(stream):
        var buffer: array[clientMessage.len, byte]
        await stream.readExactly(addr buffer, clientMessage.len)
        check string.fromBytes(buffer) == clientMessage

        await stream.write(serverMessage)

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
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
      noExceptionWithStreamClose(stream):
        check (await stream.readLp(100)) == fromHex("1234")
        await stream.writeLp(fromHex("5678"))

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        await stream.writeLp(fromHex("1234"))
        check (await stream.readLp(100)) == fromHex("5678")

    await runSingleStreamScenario(
      ma, transportProvider, streamProvider, serverStreamHandler, clientStreamHandler
    )

  asyncTest "EOF handling - first readOnce at EOF + repeated reads":
    let ma = @[MultiAddress.init(address).tryGet()]

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        var initData: array[1, byte]
        await stream.readExactly(addr initData, 1)
        await stream.write(serverMessage)

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Quic does not signal the server about new stream
        # The peer can only accept the stream after data
        # has been sent to the stream, so we send a "hello"
        # just so the server handlers is triggered
        await stream.write(newData(1))

        var buffer: array[serverMessage.len, byte]
        await stream.readExactly(addr buffer, serverMessage.len)
        check string.fromBytes(buffer) == serverMessage

        # First readOnce after EOF
        let bytesRead = await stream.readOnce(addr buffer, 1)
        check bytesRead == 0

        # Attempting second readOnce at EOF
        expect LPStreamRemoteClosedError:
          discard await stream.readOnce(addr buffer, 1)

        # # Attempting readExactly at EOF
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
        noExceptionWithStreamClose(stream):
          var initData: array[1, byte]
          await stream.readExactly(addr initData, 1)
          # Custom pattern: closes muxer/connection inside the stream handler to force immediate shutdown.
          # Using serverHandlerSingleStream would deadlock: client waits for server task,
          # but muxer.handle() blocks reading messages until client closes its connection.
          await stream.write(serverMessage)
          await muxer.close()
          await conn.close()
      serverMuxerTask = muxer.handle()

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Quic does not signal the server about new stream
        # The peer can only accept the stream after data
        # has been sent to the stream, so we send a "hello"
        # just so the server handlers is triggered
        await stream.write(newData(1))

        var buffer: array[serverMessage.len, byte]
        await stream.readExactly(addr buffer, serverMessage.len)
        check string.fromBytes(buffer) == serverMessage
        await serverMuxerTask

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
      noExceptionWithStreamClose(stream):
        var initData: array[1, byte]
        await stream.readExactly(addr initData, 1)
        await stream.write(serverMessage)

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Quic does not signal the server about new stream
        # The peer can only accept the stream after data
        # has been sent to the stream, so we send a "hello"
        # just so the server handlers is triggered
        await stream.write(newData(1))

        var buffer: array[2 * serverMessage.len, byte]

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
      noExceptionWithStreamClose(stream):
        var initData: array[1, byte]
        await stream.readExactly(addr initData, 1)

        # Server sends data and closes its write side
        await stream.write(serverMessage)
        await stream.closeWrite()

        # Server should still be able to read from client
        var buffer: array[clientMessage.len, byte]
        await stream.readExactly(addr buffer, clientMessage.len)
        check string.fromBytes(buffer) == clientMessage

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Quic does not signal the server about new stream
        # The peer can only accept the stream after data
        # has been sent to the stream, so we send a "hello"
        # just so the server handlers is triggered
        await stream.write(newData(1))

        # Client reads server data
        var buffer: array[serverMessage.len, byte]
        await stream.readExactly(addr buffer, serverMessage.len)
        check string.fromBytes(buffer) == serverMessage

        # Server has closed write side, so further reads should EOF
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
      noExceptionWithStreamClose(stream):
        var initData: array[1, byte]
        await stream.readExactly(addr initData, 1)
        await stream.write(message)

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Quic does not signal the server about new stream
        # The peer can only accept the stream after data
        # has been sent to the stream, so we send a "hello"
        # just so the server handlers is triggered
        await stream.write(newData(1))

        let receivedData =
          await readStreamByChunkTillEOF(stream, chunkSize, messageSize)
        check receivedData == message

    await runSingleStreamScenario(
      ma, transportProvider, streamProvider, serverStreamHandler, clientStreamHandler
    )

  asyncTest "stream with multiple parallel writes":
    let ma = @[MultiAddress.init(address).tryGet()]
    const messageSize = 2 * 1024 * 1024
    const chunkSize = 256 * 1024
    const parallelWrites = 10
    let message = newData(messageSize)

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        var initData: array[1, byte]
        await stream.readExactly(addr initData, 1)

        var writeFuts: seq[Future[void]] = @[]
        for i in 0 ..< parallelWrites:
          # each write has to have unique data
          let message = newData(messageSize, uint8(i + 1))
          let fut = stream.write(message)
          writeFuts.add(fut)
        await allFutures(writeFuts)

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Quic does not signal the server about new stream
        # The peer can only accept the stream after data
        # has been sent to the stream, so we send a "hello"
        # just so the server handlers is triggered
        await stream.write(newData(1))

        const expectedSize = messageSize * parallelWrites
        let receivedData =
          await readStreamByChunkTillEOF(stream, chunkSize, expectedSize)
        check receivedData.len == expectedSize

        # each task sends unique data, but the arrival order is unpredictable.
        # we verify that all consecutive segments of the data stream contain identical values.
        # example: valid → `aaaaabbbbbccccc`; invalid → `aaabbbbbccaaccc`
        for i in 0 ..< parallelWrites:
          let offset = i * messageSize
          let expectedValue = receivedData[offset]
          # all elements of same data have to be the same
          for j in 0 ..< messageSize:
            check receivedData[offset + j] == expectedValue
            if receivedData[offset + j] != expectedValue:
              break # stop on first mismatch (not to pollute stdout)

    await runSingleStreamScenario(
      ma, transportProvider, streamProvider, serverStreamHandler, clientStreamHandler
    )

  asyncTest "server with multiple parallel connections":
    let ma = @[MultiAddress.init(address).tryGet()]
    const numConnections = 5

    proc serverHandler(server: Transport) {.async.} =
      # Accept multiple connections and handle them
      var futs: seq[Future[void]]
      for i in 0 ..< numConnections:
        let conn = await server.accept()
        let muxer = streamProvider(server, conn)
        muxer.streamHandler = proc(stream: Connection) {.async: (raises: []).} =
          noExceptionWithStreamClose(stream):
            # Read the connection ID sent by client
            var buffer: array[1, byte]
            await stream.readExactly(addr buffer, 1)

            # Echo back the connection ID
            await stream.write(@buffer)

        let startStreamHandlerAndCleanup = proc() {.async.} =
          let muxerTask = muxer.handle()
          await muxerTask
          await muxer.close()
          await conn.close()

        futs.add(startStreamHandlerAndCleanup())
      await allFutures(futs)

    proc runClient(server: Transport, connectionId: int) {.async.} =
      let client = transportProvider()
      let conn = await client.dial(server.addrs[0])
      let muxer = streamProvider(client, conn)
      let muxerTask = muxer.handle()
      asyncSpawn muxerTask

      let stream = await muxer.newStream()
      await stream.write(@[byte(connectionId)])

      var buffer: array[1, byte]
      await stream.readExactly(addr buffer, 1)

      # Verify we got back our own connection ID
      check buffer[0] == byte(connectionId)

      await stream.close()
      await muxer.close()
      await conn.close()
      await muxerTask

    let server = transportProvider()
    await server.start(ma)
    let serverTask = serverHandler(server)

    # Start multiple concurrent clients
    var clientFuts: seq[Future[void]]
    for i in 0 ..< numConnections:
      clientFuts.add(runClient(server, i))

    await allFutures(clientFuts)
    await serverTask
    await server.stop()

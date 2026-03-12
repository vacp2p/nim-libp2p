# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

{.used.}

import chronos, stew/byteutils, std/random
import ../../../libp2p/[stream/connection, transports/transport, muxers/muxer]
import ../../tools/[stream, sync]
import ./utils

const
  serverMessage = "Privacy is necessary for an open society in the electronic age."
  clientMessage = "We can be decentralised yet cooperative."

template runTransportTest(
    transportProvider: TransportProvider,
    streamProvider: StreamProvider,
    address: MultiAddress,
) =
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
    @[address],
    transportProvider,
    streamProvider,
    serverStreamHandler,
    clientStreamHandler,
  )

template streamTransportTest*(
    transportProvider: TransportProvider,
    addressIP4: MultiAddress,
    addressIP6: Opt[MultiAddress],
    streamProvider: StreamProvider,
) =
  asyncTest "transport::ipv4":
    runTransportTest(transportProvider, streamProvider, addressIP4)

  asyncTest "transport::ipv6":
    if addressIP6.isNone:
      skip() # ipv6 not supported
      return

    runTransportTest(transportProvider, streamProvider, addressIP6.get())

  asyncTest "read/write Lp":
    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        check (await stream.readLp(100)) == fromHex("1234")
        await stream.writeLp(fromHex("5678"))

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        await stream.writeLp(fromHex("1234"))
        check (await stream.readLp(100)) == fromHex("5678")

    await runSingleStreamScenario(
      @[addressIP4],
      transportProvider,
      streamProvider,
      serverStreamHandler,
      clientStreamHandler,
    )

  asyncTest "EOF handling - first readOnce at EOF + repeated reads":
    var serverHandlerDone = newFuture[void]()

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
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

        serverHandlerDone.complete()

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        await stream.write(serverMessage)
        await stream.closeWrite()
        await serverHandlerDone

    await runSingleStreamScenario(
      @[addressIP4],
      transportProvider,
      streamProvider,
      serverStreamHandler,
      clientStreamHandler,
    )

  asyncTest "server writes after EOF":
    var clientHandlerDone = newFuture[void]()

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        var buffer: array[serverMessage.len, byte]
        await stream.readExactly(addr buffer, serverMessage.len)
        check string.fromBytes(buffer) == serverMessage

        await clientHandlerDone

        expect LPStreamEOFError:
          await stream.write(clientMessage)

    proc runClient(server: Transport) {.async.} =
      let client = transportProvider()
      let conn = await client.dial("", server.addrs[0])
      let muxer = streamProvider(conn)

      let stream = await muxer.newStream()
      await stream.write(serverMessage)
      await stream.close()
      await muxer.close()
      await conn.close()

      await sleepAsync(20.milliseconds)
      await client.stop()

      clientHandlerDone.complete()

    let server = transportProvider()
    await server.start(@[addressIP4])
    let serverTask =
      serverHandlerSingleStream(server, streamProvider, serverStreamHandler)

    await runClient(server)
    await serverTask
    await server.stop()

  asyncTest "incomplete read":
    var serverHandlerDone = newFuture[void]()

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        var buffer: array[2 * serverMessage.len, byte]

        expect LPStreamIncompleteError:
          await stream.readExactly(addr buffer, 2 * serverMessage.len)

        # Verify that partial data was read before EOF
        check string.fromBytes(buffer[0 ..< serverMessage.len]) == serverMessage

        serverHandlerDone.complete()

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        await stream.write(serverMessage)
        await stream.closeWrite()
        await serverHandlerDone

    await runSingleStreamScenario(
      @[addressIP4],
      transportProvider,
      streamProvider,
      serverStreamHandler,
      clientStreamHandler,
    )

  asyncTest "client closeWrite - server can still write":
    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Client reads server data
        var buffer: array[serverMessage.len, byte]
        await stream.readExactly(addr buffer, serverMessage.len)
        check string.fromBytes(buffer) == serverMessage

        # Server has closed write side, so further reads should EOF
        let bytesRead = await stream.readOnce(addr buffer, 1)
        check bytesRead == 0

        # Client should still be able to write back to server
        await stream.write(clientMessage)

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Server sends data and closes its write side
        await stream.write(serverMessage)
        await stream.closeWrite()

        # Verify that write after closeWrite fails
        expect LPStreamEOFError:
          await stream.write("should fail")

        # Server should still be able to read from client
        var buffer: array[clientMessage.len, byte]
        await stream.readExactly(addr buffer, clientMessage.len)
        check string.fromBytes(buffer) == clientMessage

    await runSingleStreamScenario(
      @[addressIP4],
      transportProvider,
      streamProvider,
      serverStreamHandler,
      clientStreamHandler,
    )

  asyncTest "multiple empty writes before closeWrite":
    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Even with multiple empty writes, reading should eventually get EOF
        var buffer: array[1, byte]
        let bytesRead = await stream.readOnce(addr buffer[0], 1)
        check bytesRead == 0 # Should get EOF

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Multiple empty writes
        await stream.write(@[])
        await stream.write(@[])
        await stream.write(@[])
        await stream.closeWrite()

    await runSingleStreamScenario(
      @[addressIP4],
      transportProvider,
      streamProvider,
      serverStreamHandler,
      clientStreamHandler,
    )

  asyncTest "closeWrite immediately after newStream":
    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Should get EOF immediately
        var buffer: array[1, byte]
        let bytesRead = await stream.readOnce(addr buffer[0], 1)
        check bytesRead == 0

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        # Close write immediately without any data
        await stream.closeWrite()

    await runSingleStreamScenario(
      @[addressIP4],
      transportProvider,
      streamProvider,
      serverStreamHandler,
      clientStreamHandler,
    )

  asyncTest "closing session should close all streams":
    const numStreams = 20
    const numIncomplete = 10
    const numComplete = numStreams - numIncomplete
    let successfulReadsWG = newWaitGroup(numComplete)

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        try:
          var buffer: array[clientMessage.len, byte]
          await stream.readExactly(addr buffer[0], clientMessage.len)
          check string.fromBytes(buffer) == clientMessage

          successfulReadsWG.done()
        except LPStreamIncompleteError:
          # Error is expected when muxer is closed while waiting in readExactly
          discard

    proc runClient(server: Transport) {.async.} =
      let client = transportProvider()
      let conn = await client.dial(server.addrs[0])
      let muxer = streamProvider(conn)

      # Send incomplete messages (will block)
      const incompleteClientMessage = clientMessage[0 ..< 10]
      for i in 0 ..< numIncomplete:
        let stream = await muxer.newStream()
        await stream.write(incompleteClientMessage)

      # Send complete messages (will finish successfully)
      for i in 0 ..< numComplete:
        let stream = await muxer.newStream()
        await stream.write(clientMessage)

      # Wait for all complete handlers to finish
      await successfulReadsWG.wait()

      # Will cause EOF on the waiting handlers 
      # Intentionally do not close streams, they should be closed with muxer
      await muxer.close()
      await conn.close()
      await client.stop()

    let server = transportProvider()
    await server.start(@[addressIP4])
    let serverTask =
      serverHandlerSingleStream(server, streamProvider, serverStreamHandler)

    await runClient(server)
    await serverTask
    await server.stop()

  asyncTest "stream caching with multiple partial reads":
    const messageSize = 2048
    const chunkSize = 256
    let message = newData(messageSize)
    var serverHandlerDone = newFuture[void]()

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        let receivedData =
          await readStreamByChunkTillEOF(stream, chunkSize, messageSize)
        check receivedData == message
        serverHandlerDone.complete()

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        await stream.write(message)
        await serverHandlerDone

    await runSingleStreamScenario(
      @[addressIP4],
      transportProvider,
      streamProvider,
      serverStreamHandler,
      clientStreamHandler,
    )

  asyncTest "stream with multiple parallel writes":
    const messageSize = 2 * 1024 * 1024
    const chunkSize = 256 * 1024
    const parallelWrites = 10
    let message = newData(messageSize)
    var serverHandlerDone = newFuture[void]()

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
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

        serverHandlerDone.complete()

    proc clientStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        var writeFuts: seq[Future[void]] = @[]
        for i in 0 ..< parallelWrites:
          # each write has to have unique data
          let message = newData(messageSize, uint8(i + 1))
          let fut = stream.write(message)
          writeFuts.add(fut)
        await allFutures(writeFuts)
        await serverHandlerDone

    await runSingleStreamScenario(
      @[addressIP4],
      transportProvider,
      streamProvider,
      serverStreamHandler,
      clientStreamHandler,
    )

  asyncTest "connection with multiple parallel streams":
    const chunkSize = 64
    const chunkCount = 32
    const messageSize = chunkSize * chunkCount
    const numStreams = 5
    var serverReadOrder: seq[byte] = @[]
    let serverHandlerWG = newWaitGroup(numStreams)

    proc serverStreamHandler(stream: Connection) {.async: (raises: []).} =
      noExceptionWithStreamClose(stream):
        var receivedData: seq[byte] = @[]

        while receivedData.len < messageSize:
          var chunk = newSeq[byte](chunkSize)
          let bytesRead = await stream.readOnce(addr chunk[0], chunkSize)
          if bytesRead == 0:
            break
          receivedData.add(chunk[0 ..< bytesRead])
          serverReadOrder.add(chunk[0])
          # Random delay between reads to allow parallel data transition between streams.
          await sleepAsync(rand(20 .. 100).milliseconds)

        check receivedData.len == messageSize

        # Send back the stream ID (first byte of received data)
        await stream.write(@[byte(receivedData[0])])

        serverHandlerWG.done()

    proc runClient(server: Transport) {.async.} =
      let client = transportProvider()
      let conn = await client.dial(server.addrs[0])
      let muxer = streamProvider(conn)

      var futs: seq[Future[void]]
      for i in 0 ..< numStreams:
        let stream = await muxer.newStream()

        # Use a capturing proc to properly bind loop variables
        proc startWriteAndClose(
            stream: Connection, streamId: int
        ): Future[void] {.async.} =
          # Write data in chunks with random delays
          for j in 0 ..< chunkCount:
            let chunkMessage = newData(chunkSize, byte(streamId))
            await stream.write(chunkMessage)
            await sleepAsync(rand(20 .. 100).milliseconds)

          # Read response from server to verify stream independence
          var buffer: array[1, byte]
          await stream.readExactly(addr buffer, 1)

          # Verify we got back our own stream ID
          check buffer[0] == byte(streamId)

          await stream.close()

        futs.add(startWriteAndClose(stream, i))

      await allFutures(futs)

      # Wait for server to process all streams before closing muxer
      await serverHandlerWG.wait()

      await muxer.close()
      await conn.close()
      await client.stop()

    let server = transportProvider()
    await server.start(@[addressIP4])
    let serverTask =
      serverHandlerSingleStream(server, streamProvider, serverStreamHandler)

    await runClient(server)
    await serverTask
    await server.stop()

    # Assert parallelism by counting transitions between different stream IDs
    # Total reads: 5 streams × 32 chunks = 160
    # Max possible transitions: 159 (change on every read except the first)
    # Sequential execution would have only 4 transitions [0,0,0,1,1,1,3,3,3,2,2,2,4,4,4]
    # We expect at least 50%
    check countTransitions(serverReadOrder) >= (numStreams * chunkCount) div 2
    echo serverReadOrder

  asyncTest "server with multiple parallel connections":
    const chunkSize = 64
    const chunkCount = 32
    const messageSize = chunkSize * chunkCount
    const errorClientId: byte = 0xff
    const numConnections = 5
    doAssert numConnections < errorClientId
    var serverReadOrder: seq[byte] = @[]

    # Track when stream handlers complete
    var serverStreamHandlerFuts: array[numConnections, Future[void]]
    for i in 0 ..< numConnections:
      serverStreamHandlerFuts[i] = newFuture[void]()

    proc serverHandler(server: Transport) {.async.} =
      # Accept multiple connections and handle them
      var futs: seq[Future[void]]
      for i in 0 ..< numConnections:
        # Use a proc to properly capture loop index
        proc setupConnection(conn: Connection, handlerIndex: int) =
          let muxer = streamProvider(conn, false)
          muxer.streamHandler = proc(stream: Connection) {.async: (raises: []).} =
            noExceptionWithStreamClose(stream):
              # Read data in chunks with random delay
              var receivedData: seq[byte] = @[]
              while receivedData.len < messageSize:
                var chunk = newSeq[byte](chunkSize)
                let bytesRead = await stream.readOnce(addr chunk[0], chunkSize)
                if bytesRead == 0:
                  break
                receivedData.add(chunk[0 ..< bytesRead])
                serverReadOrder.add(chunk[0])
                # Random delay between reads (20-100ms)
                # Will block current future (stream handler) and give opportunity to next future to execute. 
                # Doing this improves likelihood of parallel data transition on the connections.
                await sleepAsync(rand(20 .. 100).milliseconds)

              let
                # Get the client ID from any byte of the data; can't depend on accept/dial order.
                clientId =
                  if receivedData.len > 0:
                    receivedData[0]
                  else:
                    errorClientId

              check receivedData == newData(messageSize, clientId)

              # Send back ID
              await stream.write(@[clientId])

              # Signal that this stream handler is done
              serverStreamHandlerFuts[handlerIndex].complete()

          let startStreamHandlerAndCleanup = proc() {.async.} =
            await muxer.handle()

            # Wait for the stream handler to complete before closing
            await serverStreamHandlerFuts[handlerIndex]

            await muxer.close()
            await conn.close()

          futs.add(startStreamHandlerAndCleanup())

        let conn = await server.accept()
        setupConnection(conn, i)
      await allFutures(futs)

    proc runClient(server: Transport, connectionId: int) {.async.} =
      let client = transportProvider()
      let conn = await client.dial(server.addrs[0])
      let muxer = streamProvider(conn)

      let stream = await muxer.newStream()

      # Write data in chunks with random delay
      let message = newData(chunkSize, byte(connectionId))
      for i in 0 ..< chunkCount:
        await stream.write(message)
        # Random delay between writes (20-100ms)
        await sleepAsync(rand(20 .. 100).milliseconds)

      var buffer: array[1, byte]
      await stream.readExactly(addr buffer, 1)

      # Verify we got back our own connection ID
      check buffer[0] == byte(connectionId)

      await stream.close()
      await muxer.close()
      await conn.close()
      await client.stop()

    let server = transportProvider()
    await server.start(@[addressIP4])
    let serverTask = serverHandler(server)

    # Start multiple concurrent clients
    var clientFuts: seq[Future[void]]
    for i in 0 ..< numConnections:
      clientFuts.add(runClient(server, i))

    await allFutures(clientFuts)
    await serverTask
    await server.stop()

    # Assert parallelism by counting transitions between different connection IDs
    # Total reads: 5 connections × 32 chunks = 160
    # Max possible transitions: 159 (change on every read except the first)
    # Sequential execution would have only 4 transitions [0,0,0,1,1,1,3,3,3,2,2,2,4,4,4]
    # We expect at least 50%
    # TODO: nim-libp2p#1859 Tor transport: Server with multiple connections processes data sequentially in the tests
    if not (isTorTransport(addressIP4)):
      check countTransitions(serverReadOrder) >= (numConnections * chunkCount) div 2
    echo serverReadOrder

{.used.}

import chronos
import random
import sequtils
import stew/byteutils
import
  ../../libp2p/[transports/transport, transports/quictransport, upgrademngrs/upgrade]
import ../helpers
import ./basic_tests
import ./utils

proc quicTransProvider(): Transport {.gcsafe, raises: [].} =
  try:
    return QuicTransport.new(Upgrade(), PrivateKey.random(ECDSA, (newRng())[]).tryGet())
  except ResultError[crypto.CryptoError]:
    raiseAssert "should not happen"

const validAddresses =
  @[
    "/ip4/127.0.0.1/udp/1234/quic-v1", "/ip6/::1/udp/1234/quic-v1",
    "/dns/example.com/udp/1234/quic-v1",
  ]

const invalidAddresses =
  @[
    "/ip4/127.0.0.1/udp/1234", # UDP without quic-v1
    "/ip4/127.0.0.1/tcp/1234/quic-v1", # Wrong transport (TCP instead of UDP)
    "/ip4/127.0.0.1/udp/1234/quic", # Legacy quic (not quic-v1)
  ]

suite "Quic transport":
  teardown:
    checkTrackers()

  basicTransportTest(
    quicTransProvider, "/ip4/127.0.0.1/udp/0/quic-v1", validAddresses, invalidAddresses
  )

  asyncTest "transport e2e":
    let server = await createTransport(isServer = true)
    asyncSpawn createServerAcceptConn(server)()
    defer:
      await server.stop()

    proc runClient() {.async.} =
      let client = await createTransport()
      let conn = await client.dial("", server.addrs[0])
      let stream = await getStream(QuicSession(conn), Direction.Out)
      await stream.write("client")
      var resp: array[6, byte]
      await stream.readExactly(addr resp, 6)
      await stream.close()
      check string.fromBytes(resp) == "server"
      await client.stop()

    await runClient()

  asyncTest "transport e2e - invalid cert - server":
    let server = await createTransport(isServer = true, withInvalidCert = true)
    asyncSpawn createServerAcceptConn(server)()
    defer:
      await server.stop()

    proc runClient() {.async.} =
      let client = await createTransport()
      expect QuicTransportDialError:
        discard await client.dial("", server.addrs[0])
      await client.stop()

    await runClient()

  asyncTest "transport e2e - invalid cert - client":
    let server = await createTransport(isServer = true)
    asyncSpawn createServerAcceptConn(server)()
    defer:
      await server.stop()

    proc runClient() {.async.} =
      let client = await createTransport(withInvalidCert = true)
      expect QuicTransportDialError:
        discard await client.dial("", server.addrs[0])
      await client.stop()

    await runClient()

  asyncTest "should allow multiple local addresses":
    # TODO(#1663): handle multiple addr
    # See test example in commonTransportTest
    return

  asyncTest "server not accepting":
    let server = await createTransport(isServer = true)
    # intentionally not calling createServerAcceptConn as server should not accept
    defer:
      await server.stop()

    proc runClient() {.async.} =
      # client should be able to write even when server has not accepted
      let client = await createTransport()
      let conn = await client.dial("", server.addrs[0])
      let stream = await getStream(QuicSession(conn), Direction.Out)
      await stream.write("client")
      await client.stop()

    await runClient()

  asyncTest "closing session should close all streams":
    let server = await createTransport(isServer = true)
    # because some clients will not write full message, 
    # it is expected for server to receive eof
    asyncSpawn createServerAcceptConn(server, true)()
    defer:
      await server.stop()

    proc runClient() {.async.} =
      let client = await createTransport()
      let conn = await client.dial("", server.addrs[0])
      let session = QuicSession(conn)
      for i in 1 .. 20:
        let stream = await getStream(session, Direction.Out)

        # at random send full message "client" or just part of it.
        # if part of the message is sent server will be blocked until
        # whole message is received. if full message is sent, server might have
        # already written and closed it's stream. we want to cover both cases here.
        if rand(1) == 0: # 50% probability
          await stream.write("client")
        else:
          await stream.write("cl")

        # intentionally do not close stream, it should be closed with session below
      await session.close()
      await client.stop()

    # run multiple clients simultainiously
    await allFutures(runClient(), runClient(), runClient())

  asyncTest "read/write Lp":
    proc serverHandler(
        server: QuicTransport
    ) {.async: (raises: [transport.TransportError, LPStreamError, CancelledError]).} =
      let conn = await server.accept()
      let stream = await getStream(QuicSession(conn), Direction.In)
      check (await stream.readLp(100)) == fromHex("1234")
      await stream.writeLp(fromHex("5678"))
      await stream.close()
      await conn.close()

    proc runClient(server: QuicTransport) {.async.} =
      let client = await createTransport()
      let conn = await client.dial("", server.addrs[0])
      let stream = await getStream(QuicSession(conn), Direction.Out)
      await stream.writeLp(fromHex("1234"))
      check (await stream.readLp(100)) == fromHex("5678")
      await client.stop()

    let server = await createTransport(isServer = true)
    let serverHandlerFut = serverHandler(server)

    await runClient(server)
    await serverHandlerFut
    await server.stop()

  asyncTest "peer ID extraction from certificate":
    # Create server with known private key
    let serverPrivateKey = PrivateKey.random(ECDSA, (newRng())[]).tryGet()
    let expectedPeerId = PeerId.init(serverPrivateKey).tryGet()

    let server =
      await createTransport(isServer = true, privateKey = Opt.some(serverPrivateKey))
    let client = await createTransport()

    let acceptFut = server.accept()
    let clientConn = await client.dial("", server.addrs[0])
    let serverConn = await acceptFut

    # Upgrade without providing peer ID - should extract from certificate
    let muxer = await client.upgrade(clientConn, Opt.none(PeerId))
    check muxer.connection.peerId == expectedPeerId

    # Upgrade with explicit peer ID - should use the provided value
    let serverMuxer = await server.upgrade(serverConn, Opt.some(expectedPeerId))
    check serverMuxer.connection.peerId == expectedPeerId

    await client.stop()
    await server.stop()

  asyncTest "EOF handling - incomplete read + repeated EOF + write after close":
    const serverMessage = "server"
    const clientMessage = "client"

    proc serverHandler(
        server: QuicTransport
    ) {.async: (raises: [transport.TransportError, LPStreamError, CancelledError]).} =
      let conn = await server.accept()
      let stream = await getStream(QuicSession(conn), Direction.In)

      await stream.write(serverMessage)

      await stream.close()
      await conn.close()

    proc runClient(server: QuicTransport, serverHandlerFut: Future[void]) {.async.} =
      let client = await createTransport()
      let conn = await client.dial("", server.addrs[0])
      let stream = await getStream(QuicSession(conn), Direction.Out)

      var buffer: array[2 * serverMessage.len, byte]
      expect LPStreamEOFError:
        # Attempting readExactly incomplete data, server closes after serverMessage.len
        await stream.readExactly(addr buffer, 2 * serverMessage.len)

      # Verify that partial data was read before EOF
      check string.fromBytes(buffer[0 ..< serverMessage.len]) == serverMessage

      # Attempting readOnce at EOF
      expect LPStreamEOFError:
        discard await stream.readOnce(addr buffer, 1)

      # Attempting readExactly at EOF
      expect LPStreamEOFError:
        await stream.readExactly(addr buffer, 1)

      # Wait for server to fully close before attempting write to avoid race condition
      await serverHandlerFut

      # Attempting write after remote close
      expect LPStreamError:
        await stream.write(clientMessage)

      await stream.close()
      await conn.close()
      await client.stop()

    let server = await createTransport(isServer = true)
    let serverHandlerFut = serverHandler(server)

    await runClient(server, serverHandlerFut)
    await server.stop()

  asyncTest "server closeWrite - client can still write":
    const serverMessage = "server"
    const clientMessage = "client"

    proc serverHandler(
        server: QuicTransport
    ) {.async: (raises: [transport.TransportError, LPStreamError, CancelledError]).} =
      let conn = await server.accept()
      let stream = await getStream(QuicSession(conn), Direction.In)

      # Server sends data and closes its write side
      await stream.write(serverMessage)
      await stream.closeWrite()

      # Server should still be able to read from client
      var buffer: array[clientMessage.len, byte]
      await stream.readExactly(addr buffer, clientMessage.len)
      check string.fromBytes(buffer) == clientMessage

      await stream.close()
      await conn.close()

    proc runClient(server: QuicTransport) {.async.} =
      let client = await createTransport()
      let conn = await client.dial("", server.addrs[0])
      let stream = await getStream(QuicSession(conn), Direction.Out)

      # Client reads server data
      var buffer: array[serverMessage.len, byte]
      await stream.readExactly(addr buffer, serverMessage.len)
      check string.fromBytes(buffer) == serverMessage

      # Server has closed write side, so further reads should EOF
      expect LPStreamEOFError:
        discard await stream.readOnce(addr buffer, 1)

      # Client should still be able to write back to server
      await stream.write(clientMessage)

      await stream.close()
      await conn.close()
      await client.stop()

    let server = await createTransport(isServer = true)
    let serverHandlerFut = serverHandler(server)

    await runClient(server)
    await serverHandlerFut
    await server.stop()

  asyncTest "stream caching with multiple partial reads":
    const messageSize = 2048
    const chunkSize = 256
    let message = (0 ..< messageSize).mapIt(byte(it mod 256))

    proc serverHandler(server: QuicTransport) {.async.} =
      let conn = await server.accept()
      let stream = await getStream(QuicSession(conn), Direction.In)
      await stream.write(message)
      await stream.close()
      await conn.close()

    proc runClient(server: QuicTransport) {.async.} =
      let client = await createTransport()
      let conn = await client.dial("", server.addrs[0])
      let stream = await getStream(QuicSession(conn), Direction.Out)

      var receivedData: seq[byte] = @[]

      # Read a message chunk by chunk
      while receivedData.len < messageSize:
        var chunk: array[chunkSize, byte]
        let bytesRead = await stream.readOnce(addr chunk[0], chunkSize)
        check bytesRead > 0
        receivedData.add(chunk[0 ..< bytesRead])

      check receivedData == message

      await stream.close()
      await client.stop()

    let server = await createTransport(isServer = true)
    let serverFut = serverHandler(server)

    await runClient(server)
    await serverFut
    await server.stop()

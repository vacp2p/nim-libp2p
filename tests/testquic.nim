{.used.}

import chronos, stew/byteutils, random
import
  ../libp2p/[
    stream/connection,
    transports/transport,
    transports/quictransport,
    transports/tls/certificate,
    upgrademngrs/upgrade,
    multiaddress,
    errors,
    wire,
  ]
import ./helpers

proc createServerAcceptConn(
    server: QuicTransport, isEofExpected: bool = false
): proc(): Future[void] {.
  async: (raises: [transport.TransportError, LPStreamError, CancelledError])
.} =
  proc handler() {.
      async: (raises: [transport.TransportError, LPStreamError, CancelledError])
  .} =
    while true:
      let conn =
        try:
          await server.accept()
        except QuicTransportAcceptStopped:
          return # Transport is stopped
      if conn == nil:
        continue

      let stream = await getStream(QuicSession(conn), Direction.In)
      defer:
        await stream.close()

      try:
        var resp: array[6, byte]
        await stream.readExactly(addr resp, 6)
        check string.fromBytes(resp) == "client"
        await stream.write("server")
      except LPStreamEOFError as exc:
        if isEofExpected:
          discard
        else:
          raise exc

  return handler

proc invalidCertGenerator(
    kp: KeyPair
): CertificateX509 {.gcsafe, raises: [TLSCertificateError].} =
  try:
    let keyNew = PrivateKey.random(ECDSA, (newRng())[]).get()
    let pubkey = keyNew.getPublicKey().get()
    # invalidKp has pubkey that does not match seckey
    let invalidKp = KeyPair(seckey: kp.seckey, pubkey: pubkey)
    return generateX509(invalidKp, encodingFormat = EncodingFormat.PEM)
  except ResultError[crypto.CryptoError]:
    raiseAssert "private key should be set"

proc createTransport(
    isServer: bool = false, withInvalidCert: bool = false
): Future[QuicTransport] {.async.} =
  let privateKey = PrivateKey.random(ECDSA, (newRng())[]).tryGet()
  let trans =
    if withInvalidCert:
      QuicTransport.new(Upgrade(), privateKey, invalidCertGenerator)
    else:
      QuicTransport.new(Upgrade(), privateKey)

  if isServer: # servers are started because they need to listen
    let ma = @[MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()]
    await trans.start(ma)

  return trans

suite "Quic transport":
  teardown:
    checkTrackers()

  asyncTest "can handle local address":
    let server = await createTransport(isServer = true)
    check server.handles(server.addrs[0])
    await server.stop()

  asyncTest "handle accept cancellation":
    let server = await createTransport(isServer = true)

    let acceptFut = server.accept()
    await acceptFut.cancelAndWait()
    check acceptFut.cancelled

    await server.stop()

  asyncTest "handle dial cancellation":
    let server = await createTransport(isServer = true)
    let client = await createTransport(isServer = false)

    let connFut = client.dial(server.addrs[0])
    await connFut.cancelAndWait()
    check connFut.cancelled

    await client.stop()
    await server.stop()

  asyncTest "stopping transport kills connections":
    let server = await createTransport(isServer = true)
    let client = await createTransport(isServer = false)

    let acceptFut = server.accept()
    let conn = await client.dial(server.addrs[0])
    let serverConn = await acceptFut

    await client.stop()
    await server.stop()

    check serverConn.closed()
    check conn.closed()

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

  asyncTest "quic transport start/stop events":
    let transport = await createTransport(isServer = true)
    # createTransport will call start
    check await transport.onRunning.wait().withTimeout(1.seconds)

    await transport.stop()
    check await transport.onStop.wait().withTimeout(1.seconds)

  asyncTest "EOF handling: incomplete read + repeated EOF + write after close":
    const message = "server"

    proc serverHandler(
        server: QuicTransport
    ) {.async: (raises: [transport.TransportError, LPStreamError, CancelledError]).} =
      let conn = await server.accept()
      let stream = await getStream(QuicSession(conn), Direction.In)

      await stream.write(message)

      await stream.close()
      await conn.close()

    proc runClient(server: QuicTransport) {.async.} =
      let client = await createTransport()
      let conn = await client.dial("", server.addrs[0])
      let stream = await getStream(QuicSession(conn), Direction.Out)

      var buffer: array[12, byte]
      expect LPStreamEOFError:
        # Attempting readExactly incomplete data, server closes after 6
        await stream.readExactly(addr buffer, 12)

      # Verify that partial data was read before EOF
      check string.fromBytes(buffer[0 ..< message.len]) == message

      # Attempting readOnce at EOF
      var shouldFail: byte
      expect LPStreamEOFError:
        discard await stream.readOnce(addr shouldFail, 1)

      # Attempting readExactly at EOF
      expect LPStreamEOFError:
        await stream.readExactly(addr shouldFail, 1)

      # Attempting write at EOF
      expect LPStreamError:
        await stream.write("client")

      await stream.close()
      await conn.close()
      await client.stop()

    let server = await createTransport(isServer = true)
    let serverHandlerFut = serverHandler(server)

    await runClient(server)
    await serverHandlerFut
    await server.stop()

{.used.}

import chronos, stew/byteutils
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
    server: QuicTransport
): proc(): Future[void] {.
  async: (raises: [transport.TransportError, LPStreamError, CancelledError])
.} =
  proc handler() {.
      async: (raises: [transport.TransportError, LPStreamError, CancelledError])
  .} =
    try:
      let conn = await server.accept()
      if conn == nil:
        return

      let stream = await getStream(QuicSession(conn), Direction.In)
      var resp: array[6, byte]
      await stream.readExactly(addr resp, 6)
      check string.fromBytes(resp) == "client"

      await stream.write("server")
      await stream.close()
    except QuicTransportAcceptStopped:
      discard # Transport is stopped

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

proc createTransport(withInvalidCert: bool = false): Future[QuicTransport] {.async.} =
  let ma = @[MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()]
  let privateKey = PrivateKey.random(ECDSA, (newRng())[]).tryGet()
  let trans =
    if withInvalidCert:
      QuicTransport.new(Upgrade(), privateKey, invalidCertGenerator)
    else:
      QuicTransport.new(Upgrade(), privateKey)
  await trans.start(ma)

  return trans

suite "Quic transport":
  teardown:
    checkTrackers()

  asyncTest "can handle local address":
    let trans = await createTransport()
    check trans.handles(trans.addrs[0])
    await trans.stop()

  asyncTest "transport e2e":
    let server = await createTransport()
    asyncSpawn createServerAcceptConn(server)()

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
    await server.stop()

  asyncTest "transport e2e - invalid cert - server":
    let server = await createTransport(true)
    asyncSpawn createServerAcceptConn(server)()

    proc runClient() {.async.} =
      let client = await createTransport()
      expect QuicTransportDialError:
        discard await client.dial("", server.addrs[0])
      await client.stop()

    await runClient()
    await server.stop()

  asyncTest "transport e2e - invalid cert - client":
    let server = await createTransport()
    asyncSpawn createServerAcceptConn(server)()

    proc runClient() {.async.} =
      let client = await createTransport(true)
      expect QuicTransportDialError:
        discard await client.dial("", server.addrs[0])
      await client.stop()

    await runClient()
    await server.stop()

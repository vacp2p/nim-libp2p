{.used.}

import chronos
import utils/async_tests
import errorhelpers
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

      var s = QuicSession(conn)
      for i in 0 ..< 5:
        let stream = await getStream(s, Direction.In)
        var resp: array[1000, byte]
        await stream.readExactly(addr resp, 1000)
        await stream.write(newSeq[byte](2000))
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

suite "quic transport":
  asyncTest "nil2":
    let server = await createTransport()
    asyncSpawn createServerAcceptConn(server)()

    proc runClient() {.async.} =
      let client = await createTransport()
      let conn = await client.dial("", server.addrs[0])
      var s = QuicSession(conn)
      for i in 0 ..< 5:
        let stream = await getStream(s, Direction.Out)
        await stream.write(newSeq[byte](1000))
        var resp: array[2000, byte]
        await stream.readExactly(addr resp, 2000)
        await stream.close()
      await client.stop()

    await allFuturesThrowing(runClient(),runClient())
    await server.stop()

 
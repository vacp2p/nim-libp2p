# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, stew/[byteutils, endians2]
import
  ../../libp2p/[
    transports/quictransport,
    transports/transport,
    transports/tls/certificate,
    upgrademngrs/upgrade,
    multiaddress,
    multicodec,
    muxers/muxer,
  ]
import ../tools/[unittest]

# TCP

proc isTcpTransport*(ma: MultiAddress): bool =
  # Check if this is a pure TCP transport (not WebSocket or Tor)
  ma.contains(multiCodec("tcp")).get(false) and
    not ma.contains(multiCodec("ws")).get(false) and
    not ma.contains(multiCodec("wss")).get(false) and
    not ma.contains(multiCodec("onion3")).get(false)

# TOR

proc isTorTransport*(ma: MultiAddress): bool =
  ma.contains(multiCodec("onion3")).get(false)

# WS

proc isWsTransport*(ma: MultiAddress): bool =
  ma.contains(multiCodec("ws")).get(false) or ma.contains(multiCodec("wss")).get(false)

# QUIC

proc isQuicTransport*(ma: MultiAddress): bool =
  ma.contains(multiCodec("udp")).get(false)

proc createServerAcceptConn*(
    server: QuicTransport
): proc(): Future[void] {.
  async: (raises: [transport.TransportError, LPStreamError, CancelledError])
.} =
  proc handler() {.
      async: (raises: [transport.TransportError, LPStreamError, CancelledError])
  .} =
    let conn = await server.accept()
    if conn == nil:
      return

    let stream = await getStream(QuicSession(conn), Direction.In)
    defer:
      await stream.close()

    var resp: array[6, byte]
    await stream.readExactly(addr resp, 6)
    check string.fromBytes(resp) == "client"
    await stream.write("server")

  return handler

proc invalidCertGenerator*(
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

proc createTransport*(
    isServer: bool = false,
    withInvalidCert: bool = false,
    privateKey: Opt[PrivateKey] = Opt.none(PrivateKey),
): Future[QuicTransport] {.async.} =
  let key =
    if privateKey.isNone:
      PrivateKey.random(ECDSA, (newRng())[]).tryGet()
    else:
      privateKey.get()

  let trans =
    if withInvalidCert:
      QuicTransport.new(Upgrade(), key, invalidCertGenerator)
    else:
      QuicTransport.new(Upgrade(), key)

  if isServer: # servers are started because they need to listen
    let ma = @[MultiAddress.init("/ip4/127.0.0.1/udp/0/quic-v1").tryGet()]
    await trans.start(ma)

  return trans

# Common 

type TransportProvider* = proc(): Transport {.gcsafe, raises: [].}

type StreamProvider* = proc(conn: Connection): Muxer {.gcsafe, raises: [].}

type StreamHandler* = proc(stream: Connection) {.async: (raises: []).}

proc extractPort*(ma: MultiAddress): int =
  var codec =
    if isTcpTransport(ma) or isWsTransport(ma):
      multiCodec("tcp")
    elif isQuicTransport(ma):
      multiCodec("udp")
    else:
      raiseAssert "not supported"

  # Extract port number
  let portBytes = ma[codec].tryGet().protoArgument().tryGet()
  let port = int(fromBytesBE(uint16, portBytes))
  port

template noExceptionWithStreamClose*(stream: Connection, body) =
  try:
    body
  except CatchableError as exc:
    raiseAssert "should not fail: " & exc.msg
  finally:
    await stream.close()

proc serverHandlerSingleStream*(
    server: Transport, streamProvider: StreamProvider, handler: StreamHandler
) {.async: (raises: []).} =
  try:
    let conn = await server.accept()
    let muxer = streamProvider(conn)
    muxer.streamHandler = handler

    let muxerTask = muxer.handle()

    await muxerTask
    await muxer.close()
    await conn.close()
  except CatchableError as exc:
    raiseAssert "should not fail: " & exc.msg

proc clientRunSingleStream*(
    server: Transport,
    transportProvider: TransportProvider,
    streamProvider: StreamProvider,
    handler: StreamHandler,
) {.async: (raises: []).} =
  try:
    let client = transportProvider()
    let conn = await client.dial("", server.addrs[0])
    let muxer = streamProvider(conn)
    discard muxer.handle()

    let stream = await muxer.newStream()
    await handler(stream)

    await muxer.close()
    await conn.close()
  except CatchableError as exc:
    raiseAssert "should not fail: " & exc.msg

proc runSingleStreamScenario*(
    multiAddress: seq[MultiAddress],
    transportProvider: TransportProvider,
    streamProvider: StreamProvider,
    serverStreamHandler: StreamHandler,
    clientStreamHandler: StreamHandler,
) {.async: (raises: [CancelledError, LPError]).} =
  let server = transportProvider()
  await server.start(multiAddress)
  let serverTask =
    serverHandlerSingleStream(server, streamProvider, serverStreamHandler)

  await clientRunSingleStream(
    server, transportProvider, streamProvider, clientStreamHandler
  )
  await serverTask
  await server.stop()

proc countTransitions*(readOrder: seq[byte]): int =
  var transitions = 0
  for i in 1 ..< readOrder.len:
    if readOrder[i] != readOrder[i - 1]:
      transitions += 1
  transitions

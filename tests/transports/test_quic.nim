# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.used.}

import chronos, random, stew/byteutils
import lsquic/lsquic_ffi
import
  ../../libp2p/
    [transports/transport, transports/quictransport, upgrademngrs/upgrade, muxers/muxer]
import ../tools/[unittest]
import ./basic_tests
import ./stream_tests
import ./utils

proc quicTransProvider(): Transport {.gcsafe, raises: [].} =
  try:
    return QuicTransport.new(Upgrade(), PrivateKey.random(ECDSA, (newRng())[]).tryGet())
  except ResultError[crypto.CryptoError]:
    raiseAssert "should not happen"

proc streamProvider(conn: Connection, handle: bool = true): Muxer {.raises: [].} =
  try:
    return QuicMuxer.new(conn)
  except CatchableError:
    raiseAssert "should not happen"

const
  address = "/ip4/127.0.0.1/udp/0/quic-v1"
  validAddresses =
    @[
      "/ip4/127.0.0.1/udp/1234/quic-v1", "/ip6/::1/udp/1234/quic-v1",
      "/dns/example.com/udp/1234/quic-v1",
    ]
  invalidAddresses =
    @[
      "/ip4/127.0.0.1/udp/1234", # UDP without quic-v1
      "/ip4/127.0.0.1/tcp/1234/quic-v1", # Wrong transport (TCP instead of UDP)
      "/ip4/127.0.0.1/udp/1234/quic", # Legacy quic (not quic-v1)
    ]

suite "Quic transport":
  teardown:
    checkTrackers()

  basicTransportTest(quicTransProvider, address, validAddresses, invalidAddresses)
  streamTransportTest(quicTransProvider, address, streamProvider)

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
      let conn = await client.dial("", server.addrs[0])
      # TODO: expose CRYPTO_ERROR somehow in lsquic. 
      # This is a temporary measure just to get the test to work
      # lsquic will create a connection, and once the server
      # validates the certificate, it will close the connection
      # hence why a sleep is necessary
      await sleepAsync(100.milliseconds)
      let isClosed = (cast[QuicSession](conn)).connection.isClosed
      check:
        isClosed
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
      let muxer = QuicMuxer.new(conn)
      let stream = await muxer.newStream()
      await stream.write("client")
      await client.stop()

    await runClient()

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

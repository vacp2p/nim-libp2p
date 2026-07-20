# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import chronos, random, stew/byteutils
import
  ../../../libp2p/[
    transports/transport,
    transports/quictransport,
    upgrademngrs/upgrade,
    utils/future,
    muxers/muxer,
    multiaddress,
  ]
import ../../tools/[unittest, crypto as cryptoTools, multiaddress]
import ./basic_tests
import ./stream_tests
import ./utils

proc quicTransProvider(): Transport {.gcsafe, raises: [].} =
  try:
    return QuicTransport.new(Upgrade(), PrivateKey.random(ECDSA, rng()).tryGet(), rng())
  except ResultError[crypto.CryptoError]:
    raiseAssert "should not happen"

proc streamProvider(conn: RawConn, handle: bool = true): Muxer {.raises: [].} =
  try:
    return QuicMuxer.new(conn)
  except CatchableError:
    raiseAssert "should not happen"

const
  addressIP4 = "/ip4/127.0.0.1/udp/0/quic-v1"
  addressIP6 = "/ip6/::1/udp/1234/quic-v1"
  validWireAddresses = @["/ip4/127.0.0.1/udp/1234/quic-v1", "/ip6/::1/udp/1234/quic-v1"]
  validNonWireAddresses = @["/dns/example.com/udp/1234/quic-v1"]
  invalidAddresses = @[
    "/ip4/127.0.0.1/udp/1234", # UDP without quic-v1
    "/ip4/127.0.0.1/tcp/1234/quic-v1", # Wrong transport (TCP instead of UDP)
    "/ip4/127.0.0.1/udp/1234/quic", # Legacy quic (not quic-v1)
  ]

suite "Quic transport":
  teardown:
    checkTrackers()

  test "muxer rejects a nil connection":
    expect QuicTransportError:
      discard QuicMuxer.new(RawConn(nil))

  basicTransportTest(
    quicTransProvider, addressIP4, validWireAddresses, validNonWireAddresses,
    invalidAddresses,
  )
  streamTransportTest(
    quicTransProvider,
    MultiAddress.init(addressIP4).get(),
    Opt.some(MultiAddress.init(addressIP6).get()),
    streamProvider,
  )

  asyncTest "listener-role dial sends UDP hole-punch packets":
    let packetReceived =
      Future[int].Raising([CancelledError]).init("QUIC hole-punch packet received")

    proc receivePacket(
        transp: DatagramTransport, remote: TransportAddress
    ): Future[void] {.async: (raises: []).} =
      try:
        packetReceived.completeOnce(transp.getMessage().len)
      except chronos.TransportError:
        discard

    let receiver =
      newDatagramTransport(receivePacket, local = initTAddress("127.0.0.1:0"))
    defer:
      receiver.close()

    let puncher = await createQuicTransport(isServer = true)
    defer:
      await puncher.stop()

    let remoteAddr = MultiAddress
      .init("/ip4/127.0.0.1/udp/" & $receiver.localAddress().port & "/quic-v1")
      .tryGet()
    let punchFut = puncher.dial("", remoteAddr, Opt.none(PeerId), Direction.In)
    defer:
      await punchFut.cancelAndWait()

    check (await packetReceived) == QuicHolePunchPacketSize

  asyncTest "transport e2e - invalid cert - server":
    let server = await createQuicTransport(isServer = true, withInvalidCert = true)
    let serverTask = createServerAcceptConn(server)()
    defer:
      await serverTask.cancelAndWait()
      await server.stop()

    proc runClient() {.async.} =
      let client = await createQuicTransport()
      expect QuicTransportDialError:
        discard await client.dial("", server.addrs[0])
      await client.stop()

    await runClient()

  asyncTest "transport e2e - invalid cert - client":
    let server = await createQuicTransport(isServer = true)
    let serverTask = createServerAcceptConn(server)()
    defer:
      await serverTask.cancelAndWait()
      await server.stop()

    proc runClient() {.async.} =
      let client = await createQuicTransport(withInvalidCert = true)
      let conn = await client.dial("", server.addrs[0])
      # TODO: expose CRYPTO_ERROR somehow in lsquic. 
      # This is a temporary measure just to get the test to work
      # lsquic will create a connection, and once the server
      # validates the certificate, it will close the connection
      # hence why a sleep is necessary. 
      # use expect to assert dial error after fix:
      # expect QuicTransportDialError:
      #   discard await client.dial("", server.addrs[0])
      checkUntilTimeout:
        (cast[QuicSession](conn)).closed() == true
      await client.stop()

    await runClient()

  asyncTest "dial rejects mismatched peer ID":
    let serverPrivateKey = PrivateKey.random(ECDSA, rng()).tryGet()
    let wrongPeerId = PeerId.random(rng()).tryGet()
    let server = await createQuicTransport(
      isServer = true, privateKey = Opt.some(serverPrivateKey)
    )
    let client = await createQuicTransport()
    defer:
      await client.stop()
      await server.stop()

    expect QuicTransportDialError:
      discard await client.dial("", server.addrs[0], Opt.some(wrongPeerId))

  asyncTest "should allow multiple local addresses":
    let server = await createQuicTransport(
      isServer = true, addresses = @[QuicAutoAddress, QuicAutoAddress]
    )
    defer:
      await server.stop()

    check:
      server.addrs.len == 2
      server.addrs[0] != server.addrs[1]
      extractPort(server.addrs[0]) > 0
      extractPort(server.addrs[1]) > 0

    # Dial to both addresses and verify connections are accepted
    let client1 = await createQuicTransport()
    let client2 = await createQuicTransport()
    defer:
      await allFutures(client1.stop(), client2.stop())

    let acceptFut1 = server.accept()
    let conn1 = await client1.dial("", server.addrs[0])
    let serverConn1 = await acceptFut1

    let acceptFut2 = server.accept()
    let conn2 = await client2.dial("", server.addrs[1])
    let serverConn2 = await acceptFut2

    check:
      not conn1.closed()
      not conn2.closed()
      not serverConn1.closed()
      not serverConn2.closed()

  asyncTest "dial reuses listener endpoint when available":
    let client = await createQuicTransport(isServer = true)
    let server = await createQuicTransport(isServer = true)
    defer:
      await allFutures(client.stop(), server.stop())

    let clientListenPort = extractPort(client.addrs[0])
    let acceptFut = server.accept()
    let clientConn = await client.dial("", server.addrs[0])
    let serverConn = await acceptFut
    defer:
      await allFutures(clientConn.close(), serverConn.close())

    check:
      clientConn.localAddr.isSome()
      serverConn.observedAddr.isSome()
      extractPort(clientConn.localAddr.get()) == clientListenPort
      extractPort(serverConn.observedAddr.get()) == clientListenPort

  asyncTest "dial uses dial-only endpoint with multiple listener matches":
    let client = await createQuicTransport(
      isServer = true, addresses = @[QuicAutoAddress, QuicAutoAddress]
    )
    let server = await createQuicTransport(isServer = true)
    defer:
      await allFutures(client.stop(), server.stop())

    var clientListenPorts: seq[int]
    for addr in client.addrs:
      clientListenPorts.add(extractPort(addr))

    let acceptFut = server.accept()
    let clientConn = await client.dial("", server.addrs[0])
    let serverConn = await acceptFut
    defer:
      await allFutures(clientConn.close(), serverConn.close())

    check:
      client.addrs.len == 2
      clientConn.localAddr.isSome()
      serverConn.observedAddr.isSome()
      extractPort(serverConn.observedAddr.get()) ==
        extractPort(clientConn.localAddr.get())
      extractPort(serverConn.observedAddr.get()) notin clientListenPorts

  asyncTest "dial without listener uses dial-only endpoint":
    let server = await createQuicTransport(isServer = true)
    let client = await createQuicTransport()
    defer:
      await allFutures(client.stop(), server.stop())

    let acceptFut = server.accept()
    let clientConn = await client.dial("", server.addrs[0])
    let serverConn = await acceptFut
    defer:
      await allFutures(clientConn.close(), serverConn.close())

    check:
      client.addrs.len == 0
      clientConn.localAddr.isSome()
      serverConn.observedAddr.isSome()
      extractPort(serverConn.observedAddr.get()) ==
        extractPort(clientConn.localAddr.get())

  asyncTest "dual-stack dialer reuses the matching-family listener":
    # Dialing from the listener endpoint makes the remote observe the listen port.
    # Port reuse and DCUtR hole punching depend on that.
    let dialer = await createQuicTransport(
      isServer = true, addresses = @[QuicAutoAddressIP4, QuicAutoAddressIP6]
    )
    let server =
      await createQuicTransport(isServer = true, addresses = @[QuicAutoAddressIP6])
    defer:
      await allFutures(dialer.stop(), server.stop())

    let dialerIPv6Port = extractPort(dialer.addrs.addrByFamily(IP6))

    let acceptFut = server.accept()
    let dialerConn = await dialer.dial("", server.addrs[0])
    let serverConn = await acceptFut
    defer:
      await allFutures(dialerConn.close(), serverConn.close())

    check:
      serverConn.observedAddr.isSome()
      # same port as the IPv6 listener means that listener was reused
      extractPort(serverConn.observedAddr.get()) == dialerIPv6Port

  asyncTest "dial uses an IPv6 dial-only endpoint when only an IPv4 listener exists":
    # An IPv4 socket cannot carry an IPv6 dial, so the IPv4 listener cannot be
    # reused and a separate IPv6 dial-only endpoint has to be opened.
    let dialer =
      await createQuicTransport(isServer = true, addresses = @[QuicAutoAddressIP4])
    let server =
      await createQuicTransport(isServer = true, addresses = @[QuicAutoAddressIP6])
    defer:
      await allFutures(dialer.stop(), server.stop())

    let dialerIPv4Port = extractPort(dialer.addrs[0])

    let acceptFut = server.accept()
    let dialerConn = await dialer.dial("", server.addrs[0])
    let serverConn = await acceptFut
    defer:
      await allFutures(dialerConn.close(), serverConn.close())

    check:
      dialer.addrs.len == 1
      serverConn.observedAddr.isSome()
      # a different port than the IPv4 listener means a separate endpoint was used
      extractPort(serverConn.observedAddr.get()) != dialerIPv4Port

  asyncTest "server not accepting":
    let server = await createQuicTransport(isServer = true)
    # intentionally not calling createServerAcceptConn as server should not accept
    defer:
      await server.stop()

    proc runClient() {.async.} =
      # client should be able to write even when server has not accepted
      let client = await createQuicTransport()
      let conn = await client.dial("", server.addrs[0])
      let muxer = QuicMuxer.new(conn)
      let stream = await muxer.newStream()
      await stream.write("client")
      await client.stop()

    await runClient()

  asyncTest "peer ID extraction from certificate":
    # Create server with known private key
    let serverPrivateKey = PrivateKey.random(ECDSA, rng()).tryGet()
    let expectedPeerId = PeerId.init(serverPrivateKey).tryGet()

    let server = await createQuicTransport(
      isServer = true, privateKey = Opt.some(serverPrivateKey)
    )
    let client = await createQuicTransport()

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

  asyncTest "accept on stopped transport":
    let server = await createQuicTransport(isServer = true)
    await server.stop()

    expect QuicTransportAcceptStopped:
      discard await server.accept()

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
import
  ../../libp2p/[
    autotls/service,
    stream/connection,
    transports/transport,
    transports/wstransport,
    upgrademngrs/upgrade,
    multiaddress,
    errors,
    muxers/muxer,
    muxers/mplex/mplex,
  ]
import ../tools/[crypto, unittest]
import ./basic_tests
import ./connection_tests
import ./stream_tests

proc wsTransProvider(): Transport =
  WsTransport.new(Upgrade())

# Generate cert only once to reduce execution time
var secureKey {.threadvar.}: TLSPrivateKey
var secureCert {.threadvar.}: TLSCertificate
(secureKey, secureCert) = tlsCertGenerator()

proc wsSecureTransProvider(): Transport {.gcsafe, raises: [].} =
  WsTransport.new(
    Upgrade(),
    secureKey,
    secureCert,
    Opt.none(AutotlsService),
    {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName},
  )

proc streamProvider(conn: Connection, handle: bool = true): Muxer =
  let muxer = Mplex.new(conn)
  if handle:
    asyncSpawn muxer.handle()
  muxer

const
  wsAddress = "/ip4/127.0.0.1/tcp/0/ws"
  wsSecureAddress = "/ip4/127.0.0.1/tcp/0/wss"
  validAddresses =
    @[
      # Plain WebSocket
      "/ip4/127.0.0.1/tcp/1234/ws",
      "/ip6/::1/tcp/1234/ws",
      "/dns/example.com/tcp/1234/ws",
      # Secure WebSocket
      "/ip4/127.0.0.1/tcp/1234/wss",
      "/ip4/127.0.0.1/tcp/1234/tls/ws",
      "/ip6/::1/tcp/1234/wss",
      "/dns/example.com/tcp/1234/wss",
      "/dns/example.com/tcp/1234/tls/ws",
    ]
  invalidAddresses =
    @[
      "/ip4/127.0.0.1/tcp/1234", # Missing /ws or /wss
      "/ip4/127.0.0.1/udp/1234/ws", # UDP instead of TCP
      "/ip4/127.0.0.1/udp/1234/wss", # UDP instead of TCP
      "/ip4/127.0.0.1/tcp/1234/quic-v1", # QUIC instead of WebSocket
    ]

suite "WebSocket transport":
  teardown:
    checkTrackers()

  basicTransportTest(wsTransProvider, wsAddress, validAddresses, invalidAddresses)
  basicTransportTest(
    wsSecureTransProvider, wsSecureAddress, validAddresses, invalidAddresses
  )

  connectionTransportTest(wsTransProvider, wsAddress)
  connectionTransportTest(wsSecureTransProvider, wsSecureAddress)

  streamTransportTest(wsTransProvider, wsAddress, streamProvider)
  streamTransportTest(wsSecureTransProvider, wsSecureAddress, streamProvider)

  asyncTest "Hostname verification":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/wss").tryGet()]

    # Generate cert with known keypair so we can derive the PeerId (used as CN in cert)
    let testKeyPair = KeyPair.random(PKScheme.RSA, newRng()[]).get()
    let expectedPeerId = PeerId.init(testKeyPair.pubkey).tryGet()
    let (secureKey, secureCert) = tlsCertGenerator(Opt.some(testKeyPair))

    let transport1 = WsTransport.new(
      Upgrade(),
      secureKey,
      secureCert,
      Opt.none(AutotlsService),
      {TLSFlags.NoVerifyHost},
    )

    const correctPattern = mapAnd(TCP, mapEq("wss"))
    await transport1.start(ma)
    defer:
      await transport1.stop()
    check correctPattern.match(transport1.addrs[0])
    proc acceptHandler() {.async.} =
      while true:
        let conn = await transport1.accept()
        if not isNil(conn):
          await conn.close()

    let handlerWait = acceptHandler()
    defer:
      await handlerWait.cancelAndWait()

    # PeerId is used as CN in the certificate, so it should work as hostname
    let conn = await transport1.dial($expectedPeerId, transport1.addrs[0])
    await conn.close()

    expect TransportDialError:
      discard await transport1.dial("ws.wronghostname", transport1.addrs[0])

  asyncTest "handles tls/ws":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/tls/ws").tryGet()]
    let transport1 = wsSecureTransProvider()
    const correctPattern = mapAnd(TCP, mapEq("tls"), mapEq("ws"))
    await transport1.start(ma)
    check transport1.handles(transport1.addrs[0])
    check correctPattern.match(transport1.addrs[0])

    # Would raise somewhere if this wasn't handled:
    let
      inboundConn = transport1.accept()
      outboundConn = await transport1.dial(transport1.addrs[0])
      closing = outboundConn.close()
    await (await inboundConn).close()
    await closing

    await transport1.stop()

when defined(libp2p_autotls_support):
  import ../../libp2p/[autotls/service, autotls/mockservice]

  suite "WebSocket transport with autotls":
    asyncTest "autotls certificate is used when manual tlscertificate is not spcified":
      let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/tls/ws").tryGet()]

      let key = KeyPair.random(PKScheme.RSA, newRng()[]).get()
      let (privkey, cert) = tlsCertGenerator(Opt.some(key))
      let autotls = MockAutotlsService.new()
      autotls.mockedKey = privkey
      autotls.mockedCert = cert
      await autotls.setup()

      let wstransport = WsTransport.new(
        Upgrade(),
        nil, # TLSPrivateKey
        nil, # TLSCertificate
        Opt.some(AutotlsService(autotls)),
      )
      await wstransport.start(ma)
      defer:
        await wstransport.stop()

      # TLSPrivateKey and TLSCertificate should be set
      check wstransport.secure

      # autotls should be used
      let autotlsCert = await autotls.getCertWhenReady()
      check wstransport.tlsCertificate == autotlsCert.cert

    asyncTest "manually set tlscertificate is preferred over autotls when both are specified":
      let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/tls/ws").tryGet()]

      let key = KeyPair.random(PKScheme.RSA, newRng()[]).get()
      let (privkey, cert) = tlsCertGenerator(Opt.some(key))
      let autotls = MockAutotlsService.new()
      autotls.mockedKey = privkey
      autotls.mockedCert = cert
      await autotls.setup()

      # Use different cert from autotls to verify manual cert is preferred
      let (manualKey, manualCert) = tlsCertGenerator()

      let wstransport = WsTransport.new(
        Upgrade(), manualKey, manualCert, Opt.some(AutotlsService(autotls))
      )
      await wstransport.start(ma)
      defer:
        await wstransport.stop()

      # TLSPrivateKey and TLSCertificate should be set
      check wstransport.secure

      # autotls should be ignored - manual cert should be used
      check wstransport.tlsCertificate == manualCert
      check wstransport.tlsPrivateKey == manualKey

    asyncTest "wstransport is not secure when both manual tlscertificate and autotls are not specified":
      let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/tls/ws").tryGet()]
      let wstransport = WsTransport.new(
        Upgrade(),
        nil, # TLSPrivateKey
        nil, # TLSCertificate
        Opt.none(AutotlsService),
      )
      await wstransport.start(ma)
      defer:
        await wstransport.stop()

      # TLSPrivateKey and TLSCertificate should not be set
      check not wstransport.secure

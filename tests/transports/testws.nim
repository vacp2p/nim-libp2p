{.used.}

# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

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
  ]

import ../helpers
import ./commontransport
import ./utils

suite "WebSocket transport":
  teardown:
    checkTrackers()

  basicTransportTest(wsTransProvider, "/ip4/0.0.0.0/tcp/0/ws")

  basicTransportTest(wsSecureTransProvider, "/ip4/0.0.0.0/tcp/0/wss")

  asyncTest "Hostname verification":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/wss").tryGet()]
    let transport1 = WsTransport.new(
      Upgrade(),
      TLSPrivateKey.init(SecureKey),
      TLSCertificate.init(SecureCert),
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

    # ws.test is in certificate
    let conn = await transport1.dial("ws.test", transport1.addrs[0])

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
  import bearssl/pem
  import ../../libp2p/[autotls/service, autotls/mockservice, transports/tls/certificate]

  proc generateCertAndKey(key: KeyPair): (TLSPrivateKey, TLSCertificate) =
    let certDer = generateX509(key, encodingFormat = DER).certificate
    let certPem = pemEncode(certDer, "CERTIFICATE")
    let keyPem = pemEncode(key.seckey.getRawBytes().get(), "PRIVATE KEY")
    (TLSPrivateKey.init(keyPem), TLSCertificate.init(certPem))

  suite "WebSocket transport with autotls":
    asyncTest "autotls certificate is used when manual tlscertificate is not spcified":
      let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/tls/ws").tryGet()]

      let key = KeyPair.random(PKScheme.RSA, newRng()[]).get()
      let (privkey, cert) = generateCertAndKey(key)
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
      let (privkey, cert) = generateCertAndKey(key)
      let autotls = MockAutotlsService.new()
      autotls.mockedKey = privkey
      autotls.mockedCert = cert
      await autotls.setup()

      let secureKey = TLSPrivateKey.init(SecureKey)
      let secureCert = TLSCertificate.init(SecureCert)

      let wstransport = WsTransport.new(
        Upgrade(), secureKey, secureCert, Opt.some(AutotlsService(autotls))
      )
      await wstransport.start(ma)
      defer:
        await wstransport.stop()

      # TLSPrivateKey and TLSCertificate should be set
      check wstransport.secure

      # autotls should be ignored
      check wstransport.tlsCertificate == secureCert
      check wstransport.tlsPrivateKey == secureKey

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

{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import chronos, stew/byteutils
import
  ../libp2p/[
    autotls/service,
    autotls/mockservice,
    stream/connection,
    transports/transport,
    transports/wstransport,
    upgrademngrs/upgrade,
    multiaddress,
    errors,
  ]

import ./helpers, ./commontransport

const
  AutoTLSCertificate =
    """
-----BEGIN CERTIFICATE-----
MIID5DCCA2mgAwIBAgISLHPA5xRAjh3ZwYmBw4ISA+7LMAoGCCqGSM49BAMDMFIx
CzAJBgNVBAYTAlVTMSAwHgYDVQQKExcoU1RBR0lORykgTGV0J3MgRW5jcnlwdDEh
MB8GA1UEAxMYKFNUQUdJTkcpIFBzZXVkbyBQbHVtIEU1MB4XDTI1MDcwMjE3NDQ1
M1oXDTI1MDkzMDE3NDQ1MlowADBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABAh4
VNa76Ycl6RpoZ2qfM7biZzC/nz4G7lArKBMPyMUh0EX6U22VaZdxOvTfglRUxtJa
NMleBtUhDcZd4HCkNZGjggJvMIICazAOBgNVHQ8BAf8EBAMCB4AwHQYDVR0lBBYw
FAYIKwYBBQUHAwEGCCsGAQUFBwMCMAwGA1UdEwEB/wQCMAAwHQYDVR0OBBYEFJgN
WGKp9N/2bWsjD2ugSkt/8jlBMB8GA1UdIwQYMBaAFPxG0QFDX7t7pj0waK4RuuC8
bcnTMDYGCCsGAQUFBwEBBCowKDAmBggrBgEFBQcwAoYaaHR0cDovL3N0Zy1lNS5p
LmxlbmNyLm9yZy8wXAYDVR0RAQH/BFIwUIJOKi5rNTFxemk1dXF1NWRoOGRpY3ps
bzJwZDc3djBic2Vkb2tzaXo1dnk4ZXF3MnJwaWpnZ2ozdzlnNm81ejlpcy5saWJw
MnAuZGlyZWN0MBMGA1UdIAQMMAowCAYGZ4EMAQIBMDEGA1UdHwQqMCgwJqAkoCKG
IGh0dHA6Ly9zdGctZTUuYy5sZW5jci5vcmcvNzYuY3JsMIIBDAYKKwYBBAHWeQIE
AgSB/QSB+gD4AHYA3Zk0/KXnJIDJVmh9gTSZCEmySfe1adjHvKs/XMHzbmQAAAGX
zHNiGAAABAMARzBFAiBVH0V4L9LG5ksU+hOvFVgT51WUpStneTVwdSdOGbdm6gIh
ANdv5EQZI1vOVxok4D1lh1Z7hS7nfTG5HCIBbZ19iAKOAH4A2KJiliJSBM2181NJ
WC5O1mWiRRsPJ6i2iWE2s7n8BwgAAAGXzHNnWwAIAAAFAD6beWUEAwBHMEUCIAOv
AXuiujBNXne+BzzivJGbr3F0wKK7xhxIBfr/jGgyAiEA/xpSIMMcxZmH5Q4UlZj+
EH9kAlEXwmI/MFemd7pdH54wCgYIKoZIzj0EAwMDaQAwZgIxAJXdmvcIxiLPx33H
4WgXbDfjzZHiqyn+5t+73GZUDfyVotuiOvoRPpAp0L+WRS33iQIxAPWcAtrmyb7M
/BXH2ccVFRUtAJTxajwBcN9un7GJUIAb9Fbz6EOBGTT7pukEc155Zw==
-----END CERTIFICATE-----

-----BEGIN CERTIFICATE-----
MIIEljCCAn6gAwIBAgIQRzEp1D1mDiVVv4b1zlB56jANBgkqhkiG9w0BAQsFADBm
MQswCQYDVQQGEwJVUzEzMDEGA1UEChMqKFNUQUdJTkcpIEludGVybmV0IFNlY3Vy
aXR5IFJlc2VhcmNoIEdyb3VwMSIwIAYDVQQDExkoU1RBR0lORykgUHJldGVuZCBQ
ZWFyIFgxMB4XDTI0MDMxMzAwMDAwMFoXDTI3MDMxMjIzNTk1OVowUjELMAkGA1UE
BhMCVVMxIDAeBgNVBAoTFyhTVEFHSU5HKSBMZXQncyBFbmNyeXB0MSEwHwYDVQQD
ExgoU1RBR0lORykgUHNldWRvIFBsdW0gRTUwdjAQBgcqhkjOPQIBBgUrgQQAIgNi
AATljbbcV+mqWZa3g+z0bDOuBpZOtbi48iK9rjLtPdRU0WsgVp53MW3nXFU6qVYV
zEYaYd6PSmec0Tj3R5zEp5/F+cuOjTdh3AkTMzYm1tkflocPBN5APHYZ+76WxZad
q+WjggEAMIH9MA4GA1UdDwEB/wQEAwIBhjAdBgNVHSUEFjAUBggrBgEFBQcDAgYI
KwYBBQUHAwEwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHQ4EFgQU/EbRAUNfu3um
PTBorhG64LxtydMwHwYDVR0jBBgwFoAUtfNl8v6wCpIf+zx980SgrGMlwxQwNgYI
KwYBBQUHAQEEKjAoMCYGCCsGAQUFBzAChhpodHRwOi8vc3RnLXgxLmkubGVuY3Iu
b3JnLzATBgNVHSAEDDAKMAgGBmeBDAECATArBgNVHR8EJDAiMCCgHqAchhpodHRw
Oi8vc3RnLXgxLmMubGVuY3Iub3JnLzANBgkqhkiG9w0BAQsFAAOCAgEAAtCGn4iG
cupruhkCTcoDqSIVTFgVR8JJ3GvGL7SYwIc4Fn0As66nQgnkATIzF5+gFb+CXEQD
qR2Jo+R38OeT7lQ1rNDcaJcbY6hL8cNRku3QlcfdYODZ5pgTVH04gTZUJISZKLjD
kMMcQIDZlF7iYqTvmHbn2ISSKorsJ3QKAvWhHwMoJtocSz3VeDJIep5QtbHnoXh1
/dyDx7sp8RuhC0eO9ElTgDtiA2V6JxigLPzqcnibBBR4bFLGtMNE4EvOOD/Fkd0L
hdGDbAMNd+O06n+b0rgmDvg75IgOV6fpDrdZFoiNfCckOEJh9v10uYt4pTc3B6lf
zI/X3EWP1H4VJmsYuy+OA29jPeP831sAObZtd3RWv0LQPrMfx6FCmy4AaeYEMvul
FrF6OX+JbssE+bn83F+sGEMZu/eVBwwKh3db7+2UduMdTOb8DePE3Aqlg9zofS8X
9fJXrrp+PPrdQyvM3e8DxuioWa9GLG30yD9WD6WTlSiiOrdWGOzisWpW4shFoL8u
0EfmeLVU4JVbauhOYZASQXABNeXewe9lqJWwfqaARYpRjyf+jRibn22H5NVK4Vog
l55Iq1rUgjc8r493NaNrlNwG7va7Ztkch5lJ3oL/FEVlVSK4snTbgb0b5qjQz3SA
i7rA/8QRZvOLnKNtdEUlDZNrzkZwHNluLGw=
-----END CERTIFICATE-----
"""

  AutoTLSKey =
    """
-----BEGIN PRIVATE KEY-----
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
-----END PRIVATE KEY-----
"""

  SecureKey =
    """
-----BEGIN PRIVATE KEY-----
MIICdwIBADANBgkqhkiG9w0BAQEFAASCAmEwggJdAgEAAoGBAP0yH7F7FtGunC91
IPkU+u8B4gdxiwYW0J3PrixtB1Xz3e4dfjwQqhIJlG6BxQ4myCxmSPjxP/eOOYp+
8/+A9nikbnc7H3OV8fNJhsSmPu8j8W2FsNVJzJnUQaE2yimrFR8NnvQ4MKvMBSgb
lHTLbP1aAFp+K6KPPE7pkRMUdlqFAgMBAAECgYBl0eli4yALFI/kmdK3uBMtWHGA
Es4YlcYxIFpnrTS9AQPnhN7F4uGxvT5+rhsDlN780+lWixXxRLWpF2KiBkeW8ayT
kPeWvpSy6z+4LXw633ZLfCO1r6brpqSXNWxA0q7IgzYQEfMpnkaQrE3PVP5xkmTT
k159ev138J23VfNgRQJBAP768qHOCnplKIe69SVUWlsQ5nnnybDBMq2YVATbombz
KD57iufzBgND1clIEEuC6PK2C5gzTk4HZQioJ/juOFcCQQD+NVlb1HLoK7rHXZFO
Tg3O+bwRZdo67J4pt//ijF7tLlZU/q6Kp9wHrXe1yhRV+Tow0BzBVHkc5eUM0/n7
cOqDAkAedrECb/GEig17mfSsDxX0h2Jh8jWArrR1VRvEsNEIZ8jJHk2MRNbVEQe7
0qZPv0ZBqUpdVtPmMq/5hs2vyhZlAkEA1cZ1fCUf8KD9tLS6AnjfYeRgRN07dXwQ
0hKbTKAxIBJspZN7orzg60/0sNrc2SP6zJvm4qowI54tTelhexMNEwJBAOZz72xn
EFUXKYQBbetiejnBBzFYmdA/QKmZ7kbQfDBOwG9wDPFmvnNSvSZws/bP1zcM95rq
NABr5ec1FxuJa/8=
-----END PRIVATE KEY-----
"""

  SecureCert =
    """
-----BEGIN CERTIFICATE-----
MIICjDCCAfWgAwIBAgIURjeiJmkNbBVktqXvnXh44DKx364wDQYJKoZIhvcNAQEL
BQAwVzELMAkGA1UEBhMCQVUxEzARBgNVBAgMClNvbWUtU3RhdGUxITAfBgNVBAoM
GEludGVybmV0IFdpZGdpdHMgUHR5IEx0ZDEQMA4GA1UEAwwHd3MudGVzdDAgFw0y
MTA5MTQxMTU2NTZaGA8yMDgyMDgzMDExNTY1NlowVzELMAkGA1UEBhMCQVUxEzAR
BgNVBAgMClNvbWUtU3RhdGUxITAfBgNVBAoMGEludGVybmV0IFdpZGdpdHMgUHR5
IEx0ZDEQMA4GA1UEAwwHd3MudGVzdDCBnzANBgkqhkiG9w0BAQEFAAOBjQAwgYkC
gYEA/TIfsXsW0a6cL3Ug+RT67wHiB3GLBhbQnc+uLG0HVfPd7h1+PBCqEgmUboHF
DibILGZI+PE/9445in7z/4D2eKRudzsfc5Xx80mGxKY+7yPxbYWw1UnMmdRBoTbK
KasVHw2e9Dgwq8wFKBuUdMts/VoAWn4roo88TumRExR2WoUCAwEAAaNTMFEwHQYD
VR0OBBYEFHaV2ief8/Que1wxcZ8ACfdW7NUNMB8GA1UdIwQYMBaAFHaV2ief8/Qu
e1wxcZ8ACfdW7NUNMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQELBQADgYEA
XvDtaDLShrjS9huhRVoEdUtoBdhonmFpV3HXqRs7NdTuUWooXiph9a66GVSIfUCR
iEaNOKF6OM0n7GLSDIrBeIWAxL9Ra/dFFwCxl+9wxg8yyzEJDBkAhXkrfp2b4Sx6
wdK6xU2VOAxI0GUzwzjcyNl7RDFA3ayFaGl+9+oppWM=
-----END CERTIFICATE-----
"""

suite "WebSocket transport":
  teardown:
    checkTrackers()

  proc wsTraspProvider(): Transport =
    WsTransport.new(Upgrade())

  commonTransportTest(wsTraspProvider, "/ip4/0.0.0.0/tcp/0/ws")

  proc wsSecureTranspProvider(): Transport {.gcsafe.} =
    try:
      return WsTransport.new(
        Upgrade(),
        TLSPrivateKey.init(SecureKey),
        TLSCertificate.init(SecureCert),
        nil, # autotls
        {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName},
      )
    except CatchableError:
      check(false)

  commonTransportTest(wsSecureTranspProvider, "/ip4/0.0.0.0/tcp/0/wss")

  asyncTest "Hostname verification":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/wss").tryGet()]
    let transport1 = WsTransport.new(
      Upgrade(),
      TLSPrivateKey.init(SecureKey),
      TLSCertificate.init(SecureCert),
      nil, # autotls
      {TLSFlags.NoVerifyHost},
    )

    const correctPattern = mapAnd(TCP, mapEq("wss"))
    await transport1.start(ma)
    check correctPattern.match(transport1.addrs[0])
    proc acceptHandler() {.async.} =
      while true:
        let conn = await transport1.accept()
        if not isNil(conn):
          await conn.close()

    let handlerWait = acceptHandler()

    # ws.test is in certificate
    let conn = await transport1.dial("ws.test", transport1.addrs[0])

    await conn.close()

    try:
      let conn = await transport1.dial("ws.wronghostname", transport1.addrs[0])
      check false
    except CatchableError as exc:
      check true

    await handlerWait.cancelAndWait()
    await transport1.stop()

  asyncTest "handles tls/ws":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/tls/ws").tryGet()]
    let transport1 = wsSecureTranspProvider()
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

  asyncTest "autotls certificate is used when manual tlscertificate is not specified":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/tls/ws").tryGet()]

    let autotls = MockAutotlsService.new()
    autotls.mockedKey = TLSPrivateKey.init(AutoTLSKey)
    autotls.mockedCert = TLSCertificate.init(AutoTLSCertificate)
    await autotls.setup()

    let wstransport = WsTransport.new(
      Upgrade(),
      nil, # TLSPrivateKey
      nil, # TLSCertificate
      autotls,
      {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName},
    )
    await wstransport.start(ma)
    defer:
      await wstransport.stop()

    # TLSPrivateKey and TLSCertificate should be set
    check wstransport.secure

    # autotls should be used
    check wstransport.tlsCertificate == await autotls.getCertWhenReady()

  asyncTest "manually set tlscertificate is preferred over autotls when both are specified":
    let ma = @[MultiAddress.init("/ip4/0.0.0.0/tcp/0/tls/ws").tryGet()]

    let autotls = MockAutotlsService.new()
    autotls.mockedKey = TLSPrivateKey.init(AutoTLSKey)
    autotls.mockedCert = TLSCertificate.init(AutoTLSCertificate)
    await autotls.setup()
    let secureCert = TLSCertificate.init(SecureCert)
    let secureKey = TLSPrivateKey.init(SecureKey)

    let wstransport = WsTransport.new(
      Upgrade(),
      secureKey,
      secureCert,
      autotls,
      {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName},
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
      nil, # autotls
      {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName},
    )
    await wstransport.start(ma)
    defer:
      await wstransport.stop()

    # TLSPrivateKey and TLSCertificate should not be set
    check not wstransport.secure

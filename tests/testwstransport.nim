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
    stream/connection,
    transports/transport,
    transports/wstransport,
    upgrademngrs/upgrade,
    multiaddress,
    errors,
  ]

import ./helpers, ./commontransport

const
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

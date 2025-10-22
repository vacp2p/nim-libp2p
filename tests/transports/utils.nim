{.used.}

import chronos
import stew/byteutils
import
  ../../libp2p/[
    autotls/service,
    transports/quictransport,
    transports/tcptransport,
    transports/tortransport,
    transports/transport,
    transports/wstransport,
    transports/tls/certificate,
    upgrademngrs/upgrade,
  ]
import ../helpers

# Common 

type TransportBuilder* = proc(): Transport {.gcsafe, raises: [].}

# TCP

proc tcpTransProvider*(): Transport =
  TcpTransport.new(upgrade = Upgrade())

# TOR

const torServer* = initTAddress("127.0.0.1", 9050.Port)
proc torTransProvider*(): Transport =
  TorTransport.new(torServer, {ReuseAddr}, Upgrade())

# WS

const
  SecureKey* =
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

  SecureCert* =
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

proc wsTransProvider*(): Transport =
  WsTransport.new(Upgrade())

proc wsSecureTransProvider*(): Transport {.gcsafe, raises: [].} =
  try:
    return WsTransport.new(
      Upgrade(),
      TLSPrivateKey.init(SecureKey),
      TLSCertificate.init(SecureCert),
      Opt.none(AutotlsService),
      {TLSFlags.NoVerifyHost, TLSFlags.NoVerifyServerName},
    )
  except TLSStreamProtocolError:
    check false

# QUIC

proc createServerAcceptConn*(
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

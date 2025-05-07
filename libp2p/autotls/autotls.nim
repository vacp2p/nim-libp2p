import results, chronos, chronicles, bearssl/rand, bio, strformat, json

import ./acme
import ./utils
import ../transports/tls/certificate
import ../crypto/crypto
import ../peerid

logScope:
  topics = "libp2p autotls"

const
  AutoTLSBroker = "https://registration.libp2p.direct"
  AutoTLSDNSServer = "libp2p.direct"

type SigParam = object
  k: string
  v: seq[byte]

type AutoTLSManager* = ref object
  rng: ref HmacDrbgContext
  cert: Opt[CertificateX509]
  acmeAccount*: ref ACMEAccount
  running: bool

proc new*(
    T: typedesc[AutoTLSManager],
    rng: ref HmacDrbgContext = newRng(),
    acmeAccount: ref ACMEAccount = nil,
): Future[T] {.async: (raises: [ACMEError, CancelledError]).} =
  let account =
    if acmeAccount.isNil:
      let accountKey = KeyPair.random(PKScheme.RSA, rng[]).get() # TODO: check
      (await ACMEAccount.new(accountKey))
    else:
      acmeAccount

  T(rng: rng, cert: Opt.none(CertificateX509), acmeAccount: account, running: false)

method start*(
    self: AutoTLSManager, peerId: PeerId
): Future[void] {.base, async: (raises: [ACMEError, CancelledError]).} =
  if self.running:
    return
  trace "starting AutoTLS manager"
  self.running = true

  trace "registering ACME account"
  await self.acmeAccount.register()
  # TODO: registering account with key already present returns account

  # generate autotls domain
  # *.{peerID}.libp2p.direct
  let base36PeerId = encodePeerId(peerId)
  let baseDomain = fmt"{base36PeerId}.{AutoTLSDNSServer}"
  let domain = fmt"*.{baseDomain}"

  trace "requesting challenge"
  let (dns01Challenge, finalizeURL, orderURL) =
    await self.acmeAccount.requestChallenge(@[domain])
  discard finalizeURL
  discard orderURL

  let keyAuthorization = base64UrlEncode(
    @(
      sha256.digest(
        (
          dns01Challenge.getJSONField("token").getStr & "." &
          thumbprint(self.acmeAccount.key)
        ).toByteSeq
      ).data
    )
  )
  discard keyAuthorization

method stop*(self: AutoTLSManager): Future[void] {.base, async: (raises: []).} =
  if not self.running:
    return

  trace "stopping AutoTLS manager"
  self.running = false

  # end all connections (TODO)
  # await noCancel allFutures(self.connections.mapIt(it.close()))

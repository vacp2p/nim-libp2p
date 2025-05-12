import
  results,
  chronos,
  chronicles,
  bearssl/rand,
  bio,
  strformat,
  json,
  chronos/apps/http/httpclient

import ./acme
import ./peeridauth
import ./utils
import ../transports/tls/certificate
import ../crypto/crypto
import ../peerinfo

logScope:
  topics = "libp2p autotls"

type SigParam = object
  k: string
  v: seq[byte]

type AutoTLSManager* = ref object
  rng: ref HmacDrbgContext
  cert: Opt[CertificateX509]
  acmeAccount*: ref ACMEAccount
  bearerToken*: Opt[string]
  running: bool

proc new*(
    T: typedesc[AutoTLSManager],
    rng: ref HmacDrbgContext = newRng(),
    acmeAccount: ref ACMEAccount = nil,
): Future[T] {.async: (raises: [AutoTLSError, ACMEError, CancelledError]).} =
  let account =
    if acmeAccount.isNil:
      let accountKey = KeyPair.random(PKScheme.RSA, rng[]).get() # TODO: check
      (await ACMEAccount.new(accountKey))
    else:
      acmeAccount

  T(
    rng: rng,
    cert: Opt.none(CertificateX509),
    acmeAccount: account,
    bearerToken: Opt.none(string),
    running: false,
  )

method start*(
    self: AutoTLSManager, peerInfo: PeerInfo
): Future[void] {.base, async: (raises: [AutoTLSError, CancelledError]).} =
  if self.running:
    return
  trace "starting AutoTLS manager"
  self.running = true

  trace "registering ACME account"
  await self.acmeAccount.register()

  # generate autotls domain
  # *.{peerID}.libp2p.direct
  let base36PeerId = encodePeerId(peerInfo.peerId)
  let baseDomain = fmt"{base36PeerId}.{AutoTLSDNSServer}"
  let domain = fmt"*.{baseDomain}"

  trace "requesting ACME challenge"
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

  var strMultiaddresses: seq[string] = @[]
  for ma in peerInfo.addrs:
    strMultiaddresses.add($ma)

  let payload = %*{"value": keyAuthorization, "addresses": strMultiaddresses}
  let registrationURL = fmt"{AutoTLSBroker}/v1/_acme-challenge"

  trace "sending challenge to AutoTLS broker"
  var response: HttpClientResponseRef
  var bearerToken: string
  if self.bearerToken.isSome:
    (bearerToken, response) = await peerIdAuthSend(
      registrationURL, peerInfo, payload, bearerToken = self.bearerToken
    )
    discard bearerToken
  else:
    # authenticate, send challenge and save bearerToken for future requests
    (bearerToken, response) = await peerIdAuthSend(registrationURL, peerInfo, payload)
    self.bearerToken = Opt.some(bearerToken)

method stop*(self: AutoTLSManager): Future[void] {.base, async: (raises: []).} =
  if not self.running:
    return

  trace "stopping AutoTLS manager"
  self.running = false

  # end all connections (TODO)
  # await noCancel allFutures(self.connections.mapIt(it.close()))

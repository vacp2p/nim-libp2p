import
  net,
  results,
  chronos,
  chronicles,
  bearssl/rand,
  bio,
  json,
  chronos/apps/http/httpclient

import ./acme
import ./peeridauth
import ./utils
import ../transports/tls/certificate
import ../nameresolving/dnsresolver
import ../wire
import ../crypto/crypto
import ../peerinfo

logScope:
  topics = "libp2p autotls"

type SigParam = object
  k: string
  v: seq[byte]

type AutoTLSManager* = ref object
  rng: ref HmacDrbgContext
  cert*: Opt[CertificateX509]
  acmeAccount*: ref ACMEAccount
  bearerToken*: Opt[string]
  running: bool

proc checkDNSRecords(
    ip4Domain: string, acmeChalDomain: string, retries: int = 5
): Future[bool] {.async: (raises: [AutoTLSError, CancelledError]).} =
  var dnsResolver: DnsResolver
  try:
    dnsResolver = DnsResolver.new(
      @[
        initTAddress("1.1.1.1:53"),
        initTAddress("1.0.0.1:53"),
        initTAddress("[2606:4700:4700::1111]:53"),
      ]
    )
  except TransportAddressError:
    raise newException(AutoTLSError, "Failed to initialize DNS resolver")

  var txt = await dnsResolver.resolveTxt(acmeChalDomain)

  var ip4: seq[TransportAddress]
  try:
    ip4 = await dnsResolver.resolveIp(acmeChalDomain, 0.Port)
  except:
    raise newException(AutoTLSError, "Failed to resolve IP")

  for _ in 0 .. retries:
    await sleepAsync(1.seconds)
    txt = await dnsResolver.resolveTxt(acmeChalDomain)
    try:
      var ip4 = await dnsResolver.resolveIp(acmeChalDomain, 0.Port)
    except:
      raise newException(AutoTLSError, "Failed to resolve IP")
    if txt.len > 0 and txt[0] != "not set yet" and ip4.len > 0:
      return true

  return false

proc new*(
    T: typedesc[AutoTLSManager],
    rng: ref HmacDrbgContext = newRng(),
    acmeAccount: ref ACMEAccount = nil,
): AutoTLSManager =
  T(
    rng: rng,
    cert: Opt.none(CertificateX509),
    acmeAccount: acmeAccount,
    bearerToken: Opt.none(string),
    running: false,
  )

method start*(
    self: AutoTLSManager, peerInfo: PeerInfo
): Future[void] {.base, async: (raises: [AutoTLSError, CancelledError]).} =
  if self.acmeAccount.isNil:
    let accountKey = KeyPair.random(PKScheme.RSA, self.rng[]).get() # TODO: check
    self.acmeAccount = (await ACMEAccount.new(accountKey))
  if self.running:
    return
  trace "starting AutoTLS manager"
  self.running = true

  trace "registering ACME account"
  await self.acmeAccount.register()

  # generate autotls domain
  # *.{peerID}.libp2p.direct
  let base36PeerId = encodePeerId(peerInfo.peerId)
  let baseDomain = base36PeerId & "." & AutoTLSDNSServer
  let domain = "*." & baseDomain

  trace "requesting ACME challenge"
  let (dns01Challenge, finalizeURL, orderURL) =
    await self.acmeAccount.requestChallenge(@[domain])

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
  let registrationURL = AutoTLSBroker & "/v1/_acme-challenge"

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

  # no need to do anything from this point forward if there are not public ip addresses on host
  var hostPrimaryIP: IpAddress
  try:
    hostPrimaryIP = getPrimaryIPAddr()
    if not isPublicIPv4(hostPrimaryIP):
      self.running = false
      return
  except:
    raise newException(AutoTLSError, "Failed to get primary IP address for host")

  trace "waiting for DNS record to be set"

  # if my ip address is 100.10.10.3 then the ip4Domain will be:
  #     100-10-10-3.{peerIdBase36}.libp2p.direct
  # and acme challenge TXT domain will be:
  #     _acme-challenge.{peerIdBase36}.libp2p.direct
  let dashedIpAddr = ($hostPrimaryIP).replace(".", "-")
  let acmeChalDomain = "_acme-challenge." & baseDomain
  let ip4Domain = dashedIpAddr & "." & baseDomain
  if not await checkDNSRecords(ip4Domain, acmeChalDomain, retries = 3):
    raise newException(AutoTLSError, "DNS records not set")

  trace "notifying challenge completion to ACME server"
  let chalURL = dns01Challenge.getJSONField("url").getStr
  if not await self.acmeAccount.notifyChallengeCompleted(chalURL, retries = 3):
    raise newException(AutoTLSError, "ACME challenge completion notification failed")

  trace "finalize cert request with CSR"
  if not await self.acmeAccount.finalizeCertificate(
    domain, finalizeURL, orderURL, retries = 3
  ):
    raise newException(AutoTLSError, "ACME certificate finalization request failed")

  trace "downloading certificate"
  discard self.acmeAccount.downloadCertificate(orderURL)
  # self.cert = Opt.some(self.acmeAccount.downloadCertificate(orderURL))
  # TODO: properly parse cert

  trace "installing certificate"
  trace "monitoring for certificate renewals"

method stop*(self: AutoTLSManager): Future[void] {.base, async: (raises: []).} =
  if not self.running:
    return

  trace "stopping AutoTLS manager"
  self.running = false

  # end all connections (TODO)
  # await noCancel allFutures(self.connections.mapIt(it.close()))

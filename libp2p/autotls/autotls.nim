# Nim-Libp2p
# Copyright (c) 2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.push raises: [].}
{.push public.}

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

const defaultDnsServers =
  @[
    initTAddress("1.1.1.1:53"),
    initTAddress("1.0.0.1:53"),
    initTAddress("[2606:4700:4700::1111]:53"),
  ]

type SigParam = object
  k: string
  v: seq[byte]

type AutoTLSManager* = ref object
  rng: ref HmacDrbgContext
  cert*: Opt[CertificateX509]
  acmeAccount*: ref ACMEAccount
  httpSession: HttpSessionRef
  dnsResolver*: DnsResolver
  bearerToken*: Opt[string]
  running: bool

proc checkDNSRecords(
    self: AutoTLSManager, ip4Domain: string, acmeChalDomain: string, retries: int = 5
): Future[bool] {.async: (raises: [AutoTLSError, CancelledError]).} =
  var txt: seq[string]
  var ip4: seq[TransportAddress]

  for _ in 0 .. retries:
    txt = await self.dnsResolver.resolveTxt(acmeChalDomain)
    try:
      ip4 = await self.dnsResolver.resolveIp(ip4Domain, 0.Port)
    except:
      raise newException(AutoTLSError, "Failed to resolve IP")
    if txt.len > 0 and txt[0] != "not set yet" and ip4.len > 0:
      return true
    await sleepAsync(1.seconds)

  return false

proc new*(
    T: typedesc[AutoTLSManager],
    rng: ref HmacDrbgContext = newRng(),
    acmeAccount: ref ACMEAccount = nil,
    dnsResolver: DnsResolver = DnsResolver.new(defaultDnsServers),
): AutoTLSManager =
  T(
    rng: rng,
    cert: Opt.none(CertificateX509),
    acmeAccount: acmeAccount,
    httpSession: HttpSessionRef.new(),
    dnsResolver: dnsResolver,
    bearerToken: Opt.none(string),
    running: false,
  )

method stop*(self: AutoTLSManager): Future[void] {.base, async: (raises: []).} =
  if not self.running:
    return

  trace "stopping AutoTLS manager"
  await noCancel(self.acmeAccount.session.closeWait())
  await noCancel(self.httpSession.closeWait())

  self.running = false

  # end all connections (TODO)
  # await noCancel allFutures(self.connections.mapIt(it.close()))

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

  # generate autotls domain string: "*.{peerID}.libp2p.direct"
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
      registrationURL,
      self.httpSession,
      peerInfo,
      payload,
      bearerToken = self.bearerToken,
    )
    discard bearerToken
  else:
    # authenticate, send challenge and save bearerToken for future requests
    (bearerToken, response) =
      await peerIdAuthSend(registrationURL, self.httpSession, peerInfo, payload)
    self.bearerToken = Opt.some(bearerToken)

  # no need to do anything from this point forward if there are not public ip addresses on host
  var hostPrimaryIP: IpAddress
  try:
    hostPrimaryIP = getPrimaryIPAddr()
    if not isPublicIPv4(hostPrimaryIP):
      await self.stop()
      return
  except Exception:
    raise newException(AutoTLSError, "Failed to get primary IP address for host")

  trace "waiting for DNS record to be set"

  # if my ip address is 100.10.10.3 then the ip4Domain will be:
  #     100-10-10-3.{peerIdBase36}.libp2p.direct
  # and acme challenge TXT domain will be:
  #     _acme-challenge.{peerIdBase36}.libp2p.direct
  let dashedIpAddr = ($hostPrimaryIP).replace(".", "-")
  let acmeChalDomain = "_acme-challenge." & baseDomain
  let ip4Domain = dashedIpAddr & "." & baseDomain
  if not await self.checkDNSRecords(ip4Domain, acmeChalDomain, retries = 3):
    raise newException(AutoTLSError, "DNS records not set")

  trace "notifying challenge completion to ACME server"
  let chalURL = dns01Challenge.getJSONField("url").getStr
  if not await self.acmeAccount.notifyChallengeCompleted(chalURL, retries = 3):
    raise newException(AutoTLSError, "ACME challenge completion notification failed")

  trace "finalize cert request with CSR"
  if not await self.acmeAccount.finalizeCertificate(domain, finalizeURL, orderURL):
    raise newException(AutoTLSError, "ACME certificate finalization request failed")

  trace "downloading certificate"
  echo await self.acmeAccount.downloadCertificate(orderURL)
  # self.cert = Opt.some(self.acmeAccount.downloadCertificate(orderURL))
  # TODO: properly parse cert

  trace "installing certificate"
  trace "monitoring for certificate renewals"

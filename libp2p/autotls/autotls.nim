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
import ../nameresolving/dnsresolver
import ../wire
import ../crypto/crypto
import ../peerinfo
import ../utils/heartbeat

logScope:
  topics = "libp2p autotls"

const
  DefaultDnsServers =
    @[
      initTAddress("1.1.1.1:53"),
      initTAddress("1.0.0.1:53"),
      initTAddress("[2606:4700:4700::1111]:53"),
    ]
  DefaultRenewCheckTime = 1.hours
  DefaultRenewBufferTime = 1.hours
  DefaultDnsRetries = 10
  DefaultDnsRetryTime = 1.seconds

type SigParam = object
  k: string
  v: seq[byte]

type AutoTLSManager* = ref object
  rng: ref HmacDrbgContext
  managerFut: Future[void]
  cert*: Opt[TLSCertificate]
  certExpiry*: Opt[Moment]
  certReady*: AsyncEvent
  acmeAccount*: ref ACMEAccount
  httpSession: HttpSessionRef
  dnsResolver*: DnsResolver
  peerInfo*: Opt[PeerInfo]
  bearerToken*: Opt[string]
  renewCheckTime*: Duration
  renewBufferTime*: Duration
  acmeServerURL: string
  keyAuthorization*: Opt[string]
  ipAddress: Opt[IpAddress]

proc new*(
    T: typedesc[AutoTLSManager],
    rng: ref HmacDrbgContext = newRng(),
    acmeAccount: ref ACMEAccount = nil,
    dnsResolver: DnsResolver = DnsResolver.new(DefaultDnsServers),
    acmeServerURL: string = LetsEncryptURL,
    ipAddress: Opt[IpAddress] = Opt.none(IpAddress),
): AutoTLSManager =
  T(
    rng: rng,
    managerFut: nil,
    cert: Opt.none(TLSCertificate),
    certExpiry: Opt.none(Moment),
    certReady: newAsyncEvent(),
    acmeAccount: acmeAccount,
    httpSession: HttpSessionRef.new(),
    dnsResolver: dnsResolver,
    peerInfo: Opt.none(PeerInfo),
    bearerToken: Opt.none(string),
    renewCheckTime: DefaultRenewCheckTime,
    renewBufferTime: DefaultRenewBufferTime,
    acmeServerURL: acmeServerURL,
    keyAuthorization: Opt.none(string),
    ipAddress: ipAddress,
  )

proc checkDNSRecords(
    self: AutoTLSManager,
    ip4Domain: string,
    acmeChalDomain: string,
    retries: int = DefaultDnsRetries,
): Future[bool] {.async: (raises: [AutoTLSError, CancelledError]).} =
  var txt: seq[string]
  var ip4: seq[TransportAddress]

  for _ in 0 .. retries:
    txt = await self.dnsResolver.resolveTxt(acmeChalDomain)
    try:
      ip4 = await self.dnsResolver.resolveIp(ip4Domain, 0.Port)
    except CatchableError as exc:
      error "Failed to resolve IP", description = exc.msg # retry
    if txt.len > 0 and self.keyAuthorization.isSome and
        txt[0] == self.keyAuthorization.get() and ip4.len > 0:
      return true
    await sleepAsync(DefaultDnsRetryTime)

  return false

method issueCertificate(
    self: AutoTLSManager
): Future[void] {.base, async: (raises: [AutoTLSError, CancelledError]).} =
  trace "Issuing new certificate"
  let peerInfo = self.peerInfo.valueOr:
    raise newException(AutoTLSError, "Cannot issue new certificate: peerInfo not set")

  # generate autotls domain string: "*.{peerID}.libp2p.direct"
  let base36PeerId = encodePeerId(peerInfo.peerId)
  let baseDomain = base36PeerId & "." & AutoTLSDNSServer
  let domain = "*." & baseDomain

  trace "Requesting ACME challenge"
  let (dns01Challenge, finalizeURL, orderURL) =
    await self.acmeAccount.requestChallenge(@[domain])

  self.keyAuthorization = Opt.some(
    base64UrlEncode(
      @(
        sha256.digest(
          (
            dns01Challenge.getJSONField("token").getStr & "." &
            thumbprint(self.acmeAccount.key)
          ).toByteSeq
        ).data
      )
    )
  )

  var strMultiaddresses: seq[string] = @[]
  for ma in peerInfo.addrs:
    strMultiaddresses.add($ma)

  let payload = %*{"value": self.keyAuthorization.get(), "addresses": strMultiaddresses}
  let registrationURL = "https://" & AutoTLSBroker & "/v1/_acme-challenge"

  trace "Sending challenge to AutoTLS broker"
  var response: HttpClientResponseRef
  var bearerToken: string
  if self.bearerToken.isSome:
    (bearerToken, response) = await peerIdAuthSend(
      registrationURL,
      self.httpSession,
      peerInfo,
      payload,
      self.rng,
      bearerToken = self.bearerToken,
    )
  else:
    # authenticate, send challenge and save bearerToken for future requests
    (bearerToken, response) = await peerIdAuthSend(
      registrationURL, self.httpSession, peerInfo, payload, self.rng
    )
    self.bearerToken = Opt.some(bearerToken)
  if response.status != HttpOk:
    raise newException(
      AutoTLSError, "Failed to authenticate with AutoTLS Broker at " & AutoTLSBroker
    )

  # no need to do anything from this point forward if there are not public ip addresses on host
  var hostPrimaryIP: IpAddress
  try:
    hostPrimaryIP = self.ipAddress.get(getPrimaryIPAddr())
    if not isPublicIPv4(hostPrimaryIP):
      raise newException(AutoTLSError, "Host does not have a public IPv4 address")
  except Exception as exc:
    raise newException(AutoTLSError, "Failed to get primary IP address for host", exc)

  debug "Waiting for DNS record to be set"

  # if my ip address is 100.10.10.3 then the ip4Domain will be:
  #     100-10-10-3.{peerIdBase36}.libp2p.direct
  # and acme challenge TXT domain will be:
  #     _acme-challenge.{peerIdBase36}.libp2p.direct
  let dashedIpAddr = ($hostPrimaryIP).replace(".", "-")
  let acmeChalDomain = "_acme-challenge." & baseDomain
  let ip4Domain = dashedIpAddr & "." & baseDomain
  if not await self.checkDNSRecords(ip4Domain, acmeChalDomain):
    raise newException(AutoTLSError, "DNS records not set")

  debug "Notifying challenge completion to ACME server"
  let chalURL = dns01Challenge.getJSONField("url").getStr
  if not await self.acmeAccount.notifyChallengeCompleted(chalURL):
    raise newException(AutoTLSError, "ACME challenge completion notification failed")

  debug "Finalize cert request with CSR"
  if not await self.acmeAccount.finalizeCertificate(domain, finalizeURL, orderURL):
    raise newException(AutoTLSError, "ACME certificate finalization request failed")

  debug "Downloading certificate"
  let (rawCert, expiry) = await self.acmeAccount.downloadCertificate(orderURL)

  trace "Installing certificate"
  try:
    self.cert = Opt.some(TLSCertificate.init(rawCert))
    self.certExpiry = Opt.some(asMoment(expiry))
  except TLSStreamProtocolError:
    raise newException(AutoTLSError, "Could not parse downloaded certificates")
  self.certReady.fire()

proc manageCertificate(
    self: AutoTLSManager
): Future[void] {.async: (raises: [AutoTLSError, CancelledError]).} =
  trace "Starting AutoTLS manager"

  debug "Registering ACME account"
  if self.acmeAccount.isNil:
    let accountKey = KeyPair.random(PKScheme.RSA, self.rng[]).get()
    self.acmeAccount =
      (await ACMEAccount.new(accountKey, acmeServerURL = self.acmeServerURL))
  await self.acmeAccount.register()

  heartbeat "Certificate Management", self.renewCheckTime:
    if self.cert.isNone or self.certExpiry.isNone:
      try:
        await self.issueCertificate()
      except CatchableError as e:
        error "Failed to issue certificate", err = e.msg
        break

    # AutoTLSManager will renew the cert 1h before it expires
    let expiry = self.certExpiry.get
    let waitTime: Duration = expiry - Moment.now - self.renewBufferTime
    if waitTime <= self.renewBufferTime:
      try:
        await self.issueCertificate()
      except CatchableError as e:
        error "Failed to renew certificate", err = e.msg
        break

method start*(
    self: AutoTLSManager, peerInfo: PeerInfo
): Future[void] {.base, async: (raises: [CancelledError]).} =
  if not self.managerFut.isNil:
    warn "Starting AutoTLS twice"
    return

  self.peerInfo = Opt.some(peerInfo)
  self.managerFut = self.manageCertificate()

method stop*(self: AutoTLSManager): Future[void] {.base, async: (raises: []).} =
  trace "AutoTLS stop"
  if self.managerFut.isNil:
    warn "Stopping AutoTLS without starting it"
    return

  await self.managerFut.cancelAndWait()
  self.managerFut = nil
  if not self.acmeAccount.isNil:
    await self.acmeAccount.session.closeWait()
  if not self.httpSession.isNil:
    await self.httpSession.closeWait()

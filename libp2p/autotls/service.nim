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

import net, results, json, sequtils

import chronos/apps/http/httpclient, chronos, chronicles, bearssl/rand, bearssl/pem

import
  ./acme/client,
  ./utils,
  ../crypto/crypto,
  ../nameresolving/dnsresolver,
  ../peeridauth/client,
  ../peerinfo,
  ../switch,
  ../utils/heartbeat,
  ../wire,
  ../crypto/crypto,
  ../crypto/rsa

logScope:
  topics = "libp2p autotls"

export LetsEncryptURL, AutoTLSError

const
  DefaultDnsServers* =
    @[
      initTAddress("1.1.1.1:53"),
      initTAddress("1.0.0.1:53"),
      initTAddress("[2606:4700:4700::1111]:53"),
    ]
  DefaultRenewCheckTime* = 1.hours
  DefaultRenewBufferTime = 1.hours
  DefaultMaCheckTime = 1.seconds
  DefaultIssueRetryTime = 10.seconds
  DefaultIssueRetryAttemps = 6
  DefaultWaitTimeout* = 3.seconds

  AutoTLSBroker* = "registration.libp2p.direct"
  AutoTLSDNSServer* = "libp2p.direct"
  HttpOk* = 200
  HttpCreated* = 201
  # NoneIp is needed because nim 1.6.16 can't do proper generic inference
  NoneIp = Opt.none(IpAddress)

type SigParam = object
  k: string
  v: seq[byte]

type AutotlsCert* = ref object
  cert*: TLSCertificate
  expiry*: Moment

type AutotlsConfig* = ref object
  acmeServerURL*: Uri
  dnsResolver*: DnsResolver
  ipAddress: Opt[IpAddress]
  renewCheckTime*: Duration
  renewBufferTime*: Duration
  maCheckTime: Duration
  issueRetryTime: Duration
  issueRetryAttemps: int

type AutotlsService* = ref object of Service
  acmeClient*: ACMEClient
  bearer*: Opt[BearerToken]
  brokerClient*: PeerIDAuthClient
  cert*: Opt[AutotlsCert]
  certReady*: AsyncEvent
  config*: AutotlsConfig
  managerFut: Future[void]
  peerInfo: PeerInfo
  rng*: ref HmacDrbgContext

proc new*(T: typedesc[AutotlsCert], cert: TLSCertificate, expiry: Moment): T =
  T(cert: cert, expiry: expiry)

proc new*(
    T: typedesc[AutotlsConfig],
    ipAddress: Opt[IpAddress] = NoneIp,
    nameServers: seq[TransportAddress] = DefaultDnsServers,
    acmeServerURL: Uri = parseUri(LetsEncryptURL),
    renewCheckTime: Duration = DefaultRenewCheckTime,
    renewBufferTime: Duration = DefaultRenewBufferTime,
    maCheckTime: Duration = DefaultMaCheckTime,
    issueRetryTime: Duration = DefaultIssueRetryTime,
    issueRetryAttemps: int = DefaultIssueRetryAttemps,
): T =
  T(
    dnsResolver: DnsResolver.new(nameServers),
    acmeServerURL: acmeServerURL,
    ipAddress: ipAddress,
    renewCheckTime: renewCheckTime,
    renewBufferTime: renewBufferTime,
    maCheckTime: maCheckTime,
    issueRetryTime: issueRetryTime,
    issueRetryAttemps: issueRetryAttemps,
  )

proc new*(
    T: typedesc[AutotlsService],
    rng: ref HmacDrbgContext = newRng(),
    config: AutotlsConfig = AutotlsConfig.new(),
): T =
  T(
    acmeClient: ACMEClient.new(api = ACMEApi.new(acmeServerURL = config.acmeServerURL)),
    brokerClient: PeerIDAuthClient.new(),
    bearer: Opt.none(BearerToken),
    cert: Opt.none(AutotlsCert),
    certReady: newAsyncEvent(),
    config: config,
    managerFut: nil,
    peerInfo: nil,
    rng: rng,
  )

method getCertWhenReady*(
    self: AutotlsService, timeout: Duration = DefaultWaitTimeout
): Future[TLSCertificate] {.base, async: (raises: [AutoTLSError, CancelledError]).} =
  # if await self.certReady.wait().withTimeout(timeout):
  await self.certReady.wait()
  self.certReady.clear()
  return self.cert.get.cert
  # raise newException(CancelledError, "timed out waiting for cert to be ready")

method getTLSPrivkey*(
    self: AutotlsService
): TLSPrivateKey {.base, gcsafe, raises: [AutoTLSError, TLSStreamProtocolError].} =
  let derPrivKey =
    try:
      self.acmeClient.key.seckey.rsakey.getBytes.get
    except ValueError as exc:
      raise newException(AutoTLSError, "Unable to get TLS private key", exc)
  let pemPrivKey: string = pemEncode(derPrivKey, "PRIVATE KEY")
  TLSPrivateKey.init(pemPrivKey)

method issueCertificate(
    self: AutotlsService
): Future[bool] {.
    base, async: (raises: [AutoTLSError, ACMEError, PeerIDAuthError, CancelledError])
.} =
  trace "Issuing certificate"

  if self.peerInfo.isNil():
    error "peerInfo not set"
    return false

  # generate autotls domain string: "*.{peerID}.libp2p.direct"
  let baseDomain =
    api.Domain(encodePeerId(self.peerInfo.peerId) & "." & AutoTLSDNSServer)
  let domain = api.Domain("*." & baseDomain)

  let acmeClient = self.acmeClient

  trace "Requesting ACME challenge"
  let dns01Challenge = await acmeClient.getChallenge(@[domain])
  let keyAuth = acmeClient.genKeyAuthorization(dns01Challenge.dns01.token)
  let strMultiaddresses: seq[string] = self.peerInfo.addrs.mapIt($it)
  echo strMultiaddresses
  let payload = %*{"value": keyAuth, "addresses": strMultiaddresses}
  let registrationURL = parseUri("https://" & AutoTLSBroker & "/v1/_acme-challenge")

  trace "Sending challenge to AutoTLS broker"
  # before this runs we need to make sure mutiaddresses are available
  let (bearer, response) =
    await self.brokerClient.send(registrationURL, self.peerInfo, payload, self.bearer)
  debug "Broker response", status = response.status
  if response.status != HttpOk:
    error "Failed to authenticate with AutoTLS Broker"
    return false
  if self.bearer.isNone():
    # save bearer token for future
    self.bearer = Opt.some(bearer)

  trace "Waiting for DNS record to be set"
  let dnsSet = await checkDNSRecords(
    self.config.dnsResolver, self.config.ipAddress.get(), baseDomain, keyAuth
  )
  if not dnsSet:
    error "DNS records not set"
    return false

  trace "Notifying challenge completion to ACME and downloading cert"
  let certResponse = await acmeClient.getCertificate(domain, dns01Challenge)

  trace "Installing certificate"
  let newCert =
    try:
      AutotlsCert.new(
        TLSCertificate.init(certResponse.rawCertificate),
        asMoment(certResponse.certificateExpiry),
      )
    except TLSStreamProtocolError:
      raise newException(AutoTLSError, "Could not parse downloaded certificates")
  self.cert = Opt.some(newCert)
  self.certReady.fire()
  trace "Certificate installed"
  return true

proc issueWithRetries(
    self: AutotlsService
): Future[bool] {.async: (raises: [CancelledError]).} =
  for _ in 0 ..< self.config.issueRetryAttemps:
    try:
      if await self.issueCertificate():
        return true
      await sleepAsync(self.config.issueRetryTime)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      error "Failed to issue certificate", err = exc.msg
      break
  return false

proc manage(self: AutotlsService) {.async: (raises: [CancelledError]).} =
  heartbeat "Certificate Management", self.config.renewCheckTime:
    if self.cert.isNone():
      if not await self.issueWithRetries():
        return

    # AutotlsService will renew the cert 1h before it expires
    let cert = self.cert.get
    let waitTime = cert.expiry - Moment.now - self.config.renewBufferTime
    if waitTime <= self.config.renewBufferTime:
      if not await self.issueWithRetries():
        return

method setup*(
    self: AutotlsService, switch: Switch
): Future[bool] {.async: (raises: [CancelledError]).} =
  trace "Setting up AutotlsService"
  let hasBeenSetup = await procCall Service(self).setup(switch)
  if hasBeenSetup:
    self.peerInfo = switch.peerInfo
    if self.config.ipAddress.isNone():
      try:
        self.config.ipAddress = Opt.some(getPublicIPAddress())
      except AutoTLSError as exc:
        error "Failed to get public IP address", err = exc.msg
        return false
    self.managerFut = self.manage()
  return hasBeenSetup

method stop*(
    self: AutotlsService, switch: Switch
): Future[bool] {.async: (raises: [CancelledError]).} =
  let hasBeenStopped = await procCall Service(self).stop(switch)
  if hasBeenStopped:
    await self.acmeClient.close()
    await self.brokerClient.close()
    await self.managerFut.cancelAndWait()
    self.managerFut = nil
  return hasBeenStopped

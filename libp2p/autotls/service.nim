# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import sequtils
import bearssl/pem
import chronos, chronicles, net, results, uri
import chronos/streams/tlsstream

import
  ./acme/client,
  ./broker,
  ./utils,
  ../crypto/crypto,
  ../crypto/rsa,
  ../nameresolving/nameresolver,
  ../nameresolving/dnsresolver,
  ../switch,
  ../peerinfo,
  ../transports/transport,
  ../transports/tcptransport,
  ../utils/heartbeat,
  ../utils/ipaddr,
  ../wire

logScope:
  topics = "libp2p autotls"

export LetsEncryptURL, AutoTLSError, DefaultDnsServers, DefaultBrokerURL, AutotlsBroker

const
  DefaultRenewCheckTime* = 1.hours
  DefaultRenewBufferTime* = 1.hours
  DefaultIssueRetries = 3
  DefaultIssueRetryTime = 1.seconds

  AutoTLSDNSServer* = "libp2p.direct"

type AutotlsCert* = ref object
  cert*: TLSCertificate
  privkey*: TLSPrivateKey
  expiry*: Moment

type AutotlsConfig* = object
  acmeServerURL*: Uri
  nameResolver*: NameResolver
  ipAddress: Opt[IpAddress]
  renewCheckTime*: Duration
  renewBufferTime*: Duration
  issueRetries*: int
  issueRetryTime*: Duration
  brokerURL*: string
  dnsServerURL*: string
  dnsRetries*: int
  dnsRetryTime*: Duration
  acmeRetries*: int
  acmeRetryTime*: Duration
  finalizeRetries*: int
  finalizeRetryTime*: Duration

type AutotlsService* = ref object of Service
  acmeClient*: ACMEClient
  broker*: AutotlsBroker
  cert*: Opt[AutotlsCert]
  certReady*: AsyncEvent
  running*: AsyncEvent
  config*: AutotlsConfig
  managerFut: Future[void]
  peerInfo: PeerInfo
  rng*: Rng

proc new*(
    T: typedesc[AutotlsCert],
    cert: TLSCertificate,
    privkey: TLSPrivateKey,
    expiry: Moment,
): T =
  T(cert: cert, privkey: privkey, expiry: expiry)

method getCertWhenReady*(
    self: AutotlsService
): Future[AutotlsCert] {.base, async: (raises: [AutoTLSError, CancelledError]).} =
  await self.certReady.wait()
  return self.cert.get

proc new*(
    T: typedesc[AutotlsConfig],
    ipAddress: Opt[IpAddress] = Opt.none(IpAddress),
    nameServers: seq[TransportAddress] = DefaultDnsServers,
    acmeServerURL: Uri = parseUri(LetsEncryptURL),
    renewCheckTime: Duration = DefaultRenewCheckTime,
    renewBufferTime: Duration = DefaultRenewBufferTime,
    issueRetries: int = DefaultIssueRetries,
    issueRetryTime: Duration = DefaultIssueRetryTime,
    brokerURL: string = DefaultBrokerURL,
    dnsServerURL: string = AutoTLSDNSServer,
    dnsRetries: int = 10,
    dnsRetryTime: Duration = 1.seconds,
    acmeRetries: int = 10,
    acmeRetryTime: Duration = 1.seconds,
    finalizeRetries: int = 10,
    finalizeRetryTime: Duration = 1.seconds,
): T =
  T(
    nameResolver: DnsResolver.new(nameServers),
    acmeServerURL: acmeServerURL,
    ipAddress: ipAddress,
    renewCheckTime: renewCheckTime,
    renewBufferTime: renewBufferTime,
    issueRetries: issueRetries,
    issueRetryTime: issueRetryTime,
    brokerURL: brokerURL,
    dnsServerURL: dnsServerURL,
    dnsRetries: dnsRetries,
    dnsRetryTime: dnsRetryTime,
    acmeRetries: acmeRetries,
    acmeRetryTime: acmeRetryTime,
    finalizeRetries: finalizeRetries,
    finalizeRetryTime: finalizeRetryTime,
  )

proc new*(
    T: typedesc[AutotlsService], rng: Rng, config: AutotlsConfig = AutotlsConfig.new()
): T =
  T(
    acmeClient:
      ACMEClient.new(api = ACMEApi.new(acmeServerURL = config.acmeServerURL), rng = rng),
    broker: AutotlsBroker.new(rng, brokerURL = config.brokerURL),
    cert: Opt.none(AutotlsCert),
    certReady: newAsyncEvent(),
    running: newAsyncEvent(),
    config: config,
    managerFut: nil,
    peerInfo: nil,
    rng: rng,
  )

method setup*(self: AutotlsService, switch: Switch) {.raises: [ServiceSetupError].} =
  trace "Setting up AutotlsService"
  if self.config.ipAddress.isNone():
    try:
      self.config.ipAddress = Opt.some(getPublicIPAddress())
    except ValueError, OSError:
      raise newException(
        ServiceSetupError,
        "Failed to get public IP address. Reason: " & getCurrentExceptionMsg(),
      )

method issueCertificate(
    self: AutotlsService
): Future[void] {.
    base, async: (raises: [AutoTLSError, ACMEError, PeerIDAuthError, CancelledError])
.} =
  trace "Issuing certificate"

  if self.peerInfo.isNil():
    raise newException(AutoTLSError, "Cannot issue new certificate: peerInfo not set")

  # generate autotls domain string: "*.{peerID}.{dnsServerURL}"
  let baseDomain =
    api.Domain(encodePeerId(self.peerInfo.peerId) & "." & self.config.dnsServerURL)

  trace "Requesting ACME challenge"
  let dns01Challenge =
    await self.acmeClient.getChallenge(@[api.Domain("*." & baseDomain)])
  trace "Generating key authorization"
  let keyAuth = self.acmeClient.genKeyAuthorization(dns01Challenge.dns01.token)

  let addrs = await self.peerInfo.expandAddrs()

  # broker encapsulates request construction, bearer handling and response
  # validation: it either registers the challenge or raises on failure
  await self.broker.sendChallenge(self.peerInfo, addrs, keyAuth)

  let dnsSet = await checkDNSRecords(
    self.config.nameResolver,
    self.config.ipAddress.get(),
    baseDomain,
    keyAuth,
    self.config.dnsRetries,
    self.config.dnsRetryTime,
  )
  if not dnsSet:
    raise newException(AutoTLSError, "DNS records not set")

  trace "Notifying challenge completion to ACME and downloading cert"
  let certKeyPair = KeyPair.random(PKScheme.RSA, self.rng).valueOr:
    raise newException(AutoTLSError, "Unable to generate certificate key pair")
  let derPrivKey = certKeyPair.seckey.rsakey.getBytes.valueOr:
    raise newException(AutoTLSError, "Unable to get TLS private key")

  let certificate = await self.acmeClient.getCertificate(
    api.Domain("*." & baseDomain),
    certKeyPair,
    dns01Challenge,
    self.config.acmeRetries,
    self.config.finalizeRetries,
  )

  trace "Installing certificate"
  let newCert =
    try:
      AutotlsCert.new(
        TLSCertificate.init(certificate.rawCertificate),
        TLSPrivateKey.init(derPrivKey.pemEncode("PRIVATE KEY")),
        asMoment(certificate.certificateExpiry),
      )
    except TLSStreamProtocolError as exc:
      raise newException(
        AutoTLSError, "Could not parse downloaded certificates: " & exc.msg, exc
      )
  self.cert = Opt.some(newCert)
  self.certReady.fire()
  notice "AutoTLS successfully renewed certificate"

proc hasTcpStarted(switch: Switch): bool =
  switch.transports.filterIt(it of TcpTransport and it.running).len == 0

proc tryIssueCertificate(self: AutotlsService) {.async: (raises: [CancelledError]).} =
  for _ in 0 ..< self.config.issueRetries:
    try:
      await self.issueCertificate()
      return
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      error "Failed to issue certificate", err = exc.msg
    await sleepAsync(self.config.issueRetryTime)
  error "Failed to issue certificate"

method start*(
    self: AutotlsService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  trace "Starting Autotls management"
  self.running.fire()
  self.peerInfo = switch.peerInfo

  # ensure that there's at least one TcpTransport running
  # for communicating with autotls broker
  if switch.hasTcpStarted():
    error "Could not find a running TcpTransport in switch"
    return

  proc manageCert() {.async: (raises: []).} =
    try:
      heartbeat "Certificate Management", self.config.renewCheckTime:
        if self.cert.isNone():
          await self.tryIssueCertificate()

        # AutotlsService will renew the cert 1h before it expires
        let cert = self.cert.valueOr:
          error "Could not issue certificate"
          return
        let waitTime = cert.expiry - Moment.now - self.config.renewBufferTime
        if waitTime <= self.config.renewBufferTime:
          await self.tryIssueCertificate()
    except CancelledError:
      trace "Autotls management cancelled"

  self.managerFut = manageCert()

method stop*(
    self: AutotlsService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  if not self.acmeClient.isNil():
    await self.acmeClient.close()
  if not self.broker.isNil():
    await self.broker.close()
  if not self.managerFut.isNil():
    await self.managerFut.cancelAndWait()
    self.managerFut = nil

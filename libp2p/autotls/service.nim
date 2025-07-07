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
  ../crypto/rsa,
  ../nameresolving/dnsresolver,
  ../peeridauth/client,
  ../peerinfo,
  ../switch,
  ../utils/heartbeat,
  ../transports/tcptransport,
  ../transports/transport,
  ../wire

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

type AutotlsService* = ref object of Service
  acmeClient*: ACMEClient
  brokerClient*: PeerIDAuthClient
  bearer*: Opt[BearerToken]
  cert*: Opt[AutotlsCert]
  certReady*: AsyncEvent
  running*: AsyncEvent
  config*: AutotlsConfig
  managerFut: Future[void]
  peerInfo: PeerInfo
  rng*: ref HmacDrbgContext

proc new*(T: typedesc[AutotlsCert], cert: TLSCertificate, expiry: Moment): T =
  T(cert: cert, expiry: expiry)

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

method getCertWhenReady*(
    self: AutotlsService
): Future[TLSCertificate] {.base, async: (raises: [AutoTLSError, CancelledError]).} =
  await self.certReady.wait()
  return self.cert.get.cert

proc new*(
    T: typedesc[AutotlsConfig],
    ipAddress: Opt[IpAddress] = NoneIp,
    nameServers: seq[TransportAddress] = DefaultDnsServers,
    acmeServerURL: Uri = parseUri(LetsEncryptURL),
    renewCheckTime: Duration = DefaultRenewCheckTime,
    renewBufferTime: Duration = DefaultRenewBufferTime,
): T =
  T(
    dnsResolver: DnsResolver.new(nameServers),
    acmeServerURL: acmeServerURL,
    ipAddress: ipAddress,
    renewCheckTime: renewCheckTime,
    renewBufferTime: renewBufferTime,
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
    running: newAsyncEvent(),
    config: config,
    managerFut: nil,
    peerInfo: nil,
    rng: rng,
  )

method setup*(
    self: AutotlsService, switch: Switch
): Future[bool] {.async: (raises: [CancelledError]).} =
  trace "Setting up AutotlsService"
  let hasBeenSetup = await procCall Service(self).setup(switch)
  if hasBeenSetup:
    if self.config.ipAddress.isNone():
      try:
        self.config.ipAddress = Opt.some(getPublicIPAddress())
      except AutoTLSError as exc:
        error "Failed to get public IP address", err = exc.msg
        return false
    self.managerFut = self.run(switch)
  return hasBeenSetup

method issueCertificate(
    self: AutotlsService
): Future[bool] {.
    base, async: (raises: [AutoTLSError, ACMEError, PeerIDAuthError, CancelledError])
.} =
  trace "Issuing certificate"

  if self.peerInfo.isNil():
    error "Cannot issue new certificate: peerInfo not set"
    return false

  # generate autotls domain string: "*.{peerID}.libp2p.direct"
  let baseDomain =
    api.Domain(encodePeerId(self.peerInfo.peerId) & "." & AutoTLSDNSServer)
  let domain = api.Domain("*." & baseDomain)

  let acmeClient = self.acmeClient

  trace "Requesting ACME challenge"
  let dns01Challenge = await acmeClient.getChallenge(@[domain])
  trace "Generating key authorization"
  let keyAuth = acmeClient.genKeyAuthorization(dns01Challenge.dns01.token)

  let addrs = await self.peerInfo.expandAddrs()
  if addrs.len == 0:
    error "Unable to authenticate with broker: no addresses"
    return false

  # TODO
  # var goodAddresses = false
  # for address in self.peerInfo.addrs:
  #   if address is public ipv4
  #     goodAddresses = true
  # if not goodAddresses:
  #   error "Unable to authenticate with broker: no good addresses"
  #   return false

  let strMultiaddresses: seq[string] = addrs.mapIt($it)
  let payload = %*{"value": keyAuth, "addresses": strMultiaddresses}
  let registrationURL = parseUri("https://" & AutoTLSBroker & "/v1/_acme-challenge")

  trace "Sending challenge to AutoTLS broker"
  let (bearer, response) =
    await self.brokerClient.send(registrationURL, self.peerInfo, payload, self.bearer)
  if self.bearer.isNone():
    # save bearer token for future
    self.bearer = Opt.some(bearer)
  if response.status != HttpOk:
    error "Failed to authenticate with AutoTLS Broker at " & AutoTLSBroker
    debug "Broker message", body = bytesToString(response.body), peerinfo = self.peerInfo
    return false

  debug "Waiting for DNS record to be set"
  let dnsSet = await checkDNSRecords(
    self.config.dnsResolver, self.config.ipAddress.get(), baseDomain, keyAuth
  )
  if not dnsSet:
    error "DNS records not set"
    return false

  debug "Notifying challenge completion to ACME and downloading cert"
  let certResponse = await acmeClient.getCertificate(domain, dns01Challenge)

  debug "Installing certificate"
  let newCert =
    try:
      AutotlsCert.new(
        TLSCertificate.init(certResponse.rawCertificate),
        asMoment(certResponse.certificateExpiry),
      )
    except TLSStreamProtocolError:
      error "Could not parse downloaded certificates"
      return false
  self.cert = Opt.some(newCert)
  self.certReady.fire()
  debug "Certificate installed"
  true

proc tryIssueCertificate(self: AutotlsService) {.async: (raises: [CancelledError]).} =
  for _ in 0 ..< 3:
    try:
      if await self.issueCertificate():
        return
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      error "Failed to issue certificate", err = exc.msg
    await sleepAsync(3.seconds)
  error "Failed to issue certificate"

method run*(
    self: AutotlsService, switch: Switch
) {.async: (raises: [CancelledError]).} =
  trace "Starting Autotls management"
  self.running.fire()
  self.peerInfo = switch.peerInfo

  let tcpTransports =
    switch.transports.filterIt(it of TcpTransport and it.running).mapIt(TcpTransport(it))

  if tcpTransports.len == 0:
    error "Could not find a running TcpTransport in switch"
    return

  let tcpTransport = tcpTransports[0]

  heartbeat "Certificate Management", self.config.renewCheckTime:
    if self.cert.isNone():
      await self.tryIssueCertificate()

    # AutotlsService will renew the cert 1h before it expires
    let cert = self.cert.get
    let waitTime = cert.expiry - Moment.now - self.config.renewBufferTime
    if waitTime <= self.config.renewBufferTime:
      await self.tryIssueCertificate()

method stop*(
    self: AutotlsService, switch: Switch
): Future[bool] {.async: (raises: [CancelledError]).} =
  let hasBeenStopped = await procCall Service(self).stop(switch)
  if hasBeenStopped:
    if not self.acmeClient.isNil():
      await self.acmeClient.close()
    if not self.brokerClient.isNil():
      await self.brokerClient.close()
    if not self.managerFut.isNil():
      await self.managerFut.cancelAndWait()
      self.managerFut = nil
  return hasBeenStopped

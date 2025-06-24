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

import chronos/apps/http/httpclient, chronos, chronicles, bearssl/rand

import
  ./utils,
  ./acme/client,
  ../peeridauth/client,
  ../wire,
  ../crypto/crypto,
  ../peerinfo,
  ../utils/heartbeat,
  ../nameresolving/dnsresolver

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
  DefaultRenewCheckTime = 1.hours
  DefaultRenewBufferTime = 1.hours

  AutoTLSBroker* = "registration.libp2p.direct"
  AutoTLSDNSServer* = "libp2p.direct"
  HttpOk* = 200
  HttpCreated* = 201

type SigParam = object
  k: string
  v: seq[byte]

type AutoTLSManager* = ref object
  rng: ref HmacDrbgContext
  managerFut: Future[void]
  cert*: Opt[TLSCertificate]
  certExpiry*: Opt[Moment]
  certReady*: AsyncEvent
  acmeClient: Opt[ACMEClient]
  brokerClient: PeerIDAuthClient
  dnsResolver*: DnsResolver
  bearer*: Opt[BearerToken]
  renewCheckTime*: Duration
  renewBufferTime*: Duration
  peerInfo: Opt[PeerInfo]
  acmeServerURL: Uri
  ipAddress: Opt[IpAddress]

proc new*(
    T: typedesc[AutoTLSManager],
    rng: ref HmacDrbgContext = newRng(),
    acmeClient: Opt[ACMEClient] = Opt.none(ACMEClient),
    brokerClient: PeerIDAuthClient = PeerIDAuthClient.new(),
    dnsResolver: DnsResolver = DnsResolver.new(DefaultDnsServers),
    acmeServerURL: Uri = parseUri(LetsEncryptURL),
    ipAddress: Opt[IpAddress] = Opt.none(IpAddress),
): AutoTLSManager =
  T(
    rng: rng,
    managerFut: nil,
    cert: Opt.none(TLSCertificate),
    certExpiry: Opt.none(Moment),
    certReady: newAsyncEvent(),
    acmeClient: acmeClient,
    brokerClient: brokerClient,
    dnsResolver: dnsResolver,
    bearer: Opt.none(BearerToken),
    renewCheckTime: DefaultRenewCheckTime,
    renewBufferTime: DefaultRenewBufferTime,
    peerInfo: Opt.none(PeerInfo),
    acmeServerURL: acmeServerURL,
    ipAddress: ipAddress,
  )

proc getIpAddress(self: AutoTLSManager): IpAddress {.raises: [AutoTLSError].} =
  return self.ipAddress.valueOr:
    getPublicIPADdress()

method issueCertificate(
    self: AutoTLSManager
) {.base, async: (raises: [AutoTLSError, ACMEError, PeerIDAuthError, CancelledError]).} =
  trace "Issuing new certificate"
  let peerInfo = self.peerInfo.valueOr:
    raise newException(AutoTLSError, "Cannot issue new certificate: peerInfo not set")

  # generate autotls domain string: "*.{peerID}.libp2p.direct"
  let base36PeerId = encodePeerId(peerInfo.peerId)
  let baseDomain = api.Domain(base36PeerId & "." & AutoTLSDNSServer)
  let domain = api.Domain("*." & baseDomain)

  let acmeClient = self.acmeClient.valueOr:
    raise newException(AutoTLSError, "Cannot find ACMEClient on manager")

  trace "Requesting ACME challenge"
  let dns01Challenge = await acmeClient.getChallenge(@[domain])
  let keyAuth = acmeClient.genKeyAuthorization(dns01Challenge.dns01.token)
  let strMultiaddresses: seq[string] = peerInfo.addrs.mapIt($it)
  let payload = %*{"value": keyAuth, "addresses": strMultiaddresses}
  let registrationURL = parseUri("https://" & AutoTLSBroker & "/v1/_acme-challenge")

  trace "Sending challenge to AutoTLS broker"
  let (bearer, response) =
    await self.brokerClient.send(registrationURL, peerInfo, payload, self.bearer)
  if self.bearer.isNone():
    # save bearer token for future
    self.bearer = Opt.some(bearer)
  if response.status != HttpOk:
    raise newException(
      AutoTLSError, "Failed to authenticate with AutoTLS Broker at " & AutoTLSBroker
    )

  debug "Waiting for DNS record to be set"
  let dnsSet =
    await checkDNSRecords(self.dnsResolver, self.getIpAddress(), baseDomain, keyAuth)
  if not dnsSet:
    raise newException(AutoTLSError, "DNS records not set")

  debug "Notifying challenge completion to ACME and downloading cert"
  let certResponse = await acmeClient.getCertificate(domain, dns01Challenge)

  trace "Installing certificate"
  try:
    self.cert = Opt.some(TLSCertificate.init(certResponse.rawCertificate))
    self.certExpiry = Opt.some(asMoment(certResponse.certificateExpiry))
  except TLSStreamProtocolError:
    raise newException(AutoTLSError, "Could not parse downloaded certificates")
  self.certReady.fire()

proc manageCertificate(
    self: AutoTLSManager
) {.async: (raises: [AutoTLSError, ACMEError, CancelledError]).} =
  trace "Starting AutoTLS manager"

  debug "Registering ACME account"
  if self.acmeClient.isNone():
    self.acmeClient = Opt.some(await ACMEClient.new(acmeServerURL = self.acmeServerURL))

  heartbeat "Certificate Management", self.renewCheckTime:
    if self.cert.isNone() or self.certExpiry.isNone():
      try:
        await self.issueCertificate()
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        error "Failed to issue certificate", err = exc.msg
        break

    # AutoTLSManager will renew the cert 1h before it expires
    let expiry = self.certExpiry.get
    let waitTime = expiry - Moment.now - self.renewBufferTime
    if waitTime <= self.renewBufferTime:
      try:
        await self.issueCertificate()
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        error "Failed to renew certificate", err = exc.msg
        break

method start*(
    self: AutoTLSManager, peerInfo: PeerInfo
) {.base, async: (raises: [CancelledError]).} =
  if not self.managerFut.isNil():
    warn "Starting AutoTLS twice"
    return

  self.peerInfo = Opt.some(peerInfo)
  self.managerFut = self.manageCertificate()

method stop*(self: AutoTLSManager) {.base, async: (raises: [CancelledError]).} =
  trace "AutoTLS stop"
  if self.managerFut.isNil():
    warn "AutoTLS manager not running"
    return

  await self.managerFut.cancelAndWait()
  self.managerFut = nil

  if self.acmeClient.isSome():
    await self.acmeClient.get.close()

  await self.brokerClient.close()

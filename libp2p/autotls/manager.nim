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

from times import DateTime, toTime, toUnix

import chronos/apps/http/httpclient, stew/base36, chronos, chronicles, bearssl/rand

import
  ./acme/client,
  ../peeridauth/client,
  ../nameresolving/dnsresolver,
  ../wire,
  ../crypto/crypto,
  ../peerinfo,
  ../peerid,
  ../multihash,
  ../multicodec,
  ../errors,
  ../cid,
  ../utils/heartbeat

export LetsEncryptURL

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

  AutoTLSBroker* = "registration.libp2p.direct"
  AutoTLSDNSServer* = "libp2p.direct"
  HttpOk* = 200
  HttpCreated* = 201

type AutoTLSError* = object of LPError

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

proc checkedGetPrimaryIPAddr*(): IpAddress {.raises: [AutoTLSError].} =
  # This is so that we don't need to catch Exceptions directly
  # since we support 1.6.16 and getPrimaryIPAddr before nim 2 didn't have explicit .raises. pragmas
  try:
    return getPrimaryIPAddr()
  except Exception as exc:
    raise newException(AutoTLSError, "Error while getting primary IP address", exc)

proc isIPv4*(ip: IpAddress): bool =
  ip.family == IpAddressFamily.IPv4

proc isPublic*(ip: IpAddress): bool {.raises: [AutoTLSError].} =
  let ip = $ip
  try:
    not (
      ip.startsWith("10.") or
      (ip.startsWith("172.") and parseInt(ip.split(".")[1]) in 16 .. 31) or
      ip.startsWith("192.168.") or ip.startsWith("127.") or ip.startsWith("169.254.")
    )
  except ValueError as exc:
    raise newException(AutoTLSError, "Failed to parse IP address", exc)

proc asMoment*(dt: DateTime): Moment =
  let unixTime: int64 = dt.toTime.toUnix
  return Moment.init(unixTime, Second)

proc encodePeerId*(peerId: PeerId): string {.raises: [AutoTLSError].} =
  var mh: MultiHash
  let decodeResult = MultiHash.decode(peerId.data, mh)
  if decodeResult.isErr or decodeResult.get() == -1:
    raise
      newException(AutoTLSError, "Failed to decode PeerId: invalid multihash format")

  let cidResult = Cid.init(CIDv1, multiCodec("libp2p-key"), mh)
  if cidResult.isErr:
    raise newException(AutoTLSError, "Failed to initialize CID from multihash")

  return Base36.encode(cidResult.get().data.buffer)

proc checkDNSRecords(
    self: AutoTLSManager,
    ipAddress: IpAddress,
    baseDomain: api.Domain,
    keyAuth: KeyAuthorization,
    retries: int = DefaultDnsRetries,
): Future[bool] {.async: (raises: [AutoTLSError, CancelledError]).} =
  # if my ip address is 100.10.10.3 then the ip4Domain will be:
  #     100-10-10-3.{peerIdBase36}.libp2p.direct
  # and acme challenge TXT domain will be:
  #     _acme-challenge.{peerIdBase36}.libp2p.direct
  let dashedIpAddr = ($ipAddress).replace(".", "-")
  let acmeChalDomain = api.Domain("_acme-challenge." & baseDomain)
  let ip4Domain = api.Domain(dashedIpAddr & "." & baseDomain)

  var txt: seq[string]
  var ip4: seq[TransportAddress]
  for _ in 0 .. retries:
    txt = await self.dnsResolver.resolveTxt(acmeChalDomain)
    try:
      ip4 = await self.dnsResolver.resolveIp(ip4Domain, 0.Port)
    except CatchableError as exc:
      error "Failed to resolve IP", description = exc.msg # retry
    if txt.len > 0 and txt[0] == keyAuth and ip4.len > 0:
      return true
    await sleepAsync(DefaultDnsRetryTime)

  return false

method issueCertificate(
    self: AutoTLSManager
): Future[void] {.
    base, async: (raises: [AutoTLSError, ACMEError, PeerIDAuthError, CancelledError])
.} =
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
  if self.bearer.isNone:
    # save bearer token for future
    self.bearer = Opt.some(bearer)
  if response.status != HttpOk:
    raise newException(
      AutoTLSError, "Failed to authenticate with AutoTLS Broker at " & AutoTLSBroker
    )

  debug "Waiting for DNS record to be set"
  let ipAddress = self.ipAddress.valueOr:
    raise newException(AutoTLSError, "No public IPv4 address specified")

  let dnsSet = await self.checkDNSRecords(ipAddress, baseDomain, keyAuth)
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
): Future[void] {.async: (raises: [AutoTLSError, ACMEError, CancelledError]).} =
  trace "Starting AutoTLS manager"
  let ipAddress = self.ipAddress.valueOr:
    try:
      let ip = self.ipAddress.valueOr:
        checkedGetPrimaryIPAddr()
      if not ip.isIPv4:
        raise newException(AutoTLSError, "Host does not have an IPv4 address")
      if not ip.isPublic:
        raise newException(AutoTLSError, "Host does not have a public IPv4 address")
      ip
    except AutoTLSError as exc:
      raise exc
    except CatchableError as exc:
      raise newException(
        AutoTLSError, "Unexpected error while getting primary IP address for host", exc
      )
  self.ipAddress = Opt.some(ipAddress)

  debug "Registering ACME account"
  if self.acmeClient.isNone:
    self.acmeClient = Opt.some(await ACMEClient.new(acmeServerURL = self.acmeServerURL))

  heartbeat "Certificate Management", self.renewCheckTime:
    if self.cert.isNone or self.certExpiry.isNone:
      try:
        await self.issueCertificate()
      except CatchableError as exc:
        error "Failed to issue certificate", err = exc.msg
        break

    # AutoTLSManager will renew the cert 1h before it expires
    let expiry = self.certExpiry.get
    let waitTime = expiry - Moment.now - self.renewBufferTime
    if waitTime <= self.renewBufferTime:
      try:
        await self.issueCertificate()
      except CatchableError as exc:
        error "Failed to renew certificate", err = exc.msg
        break

method start*(
    self: AutoTLSManager, peerInfo: PeerInfo
): Future[void] {.base, async: (raises: [CancelledError]).} =
  if not self.managerFut.isNil:
    warn "Starting AutoTLS twice"
    return

  self.peerInfo = Opt.some(peerInfo)
  self.managerFut = self.manageCertificate()

method stop*(
    self: AutoTLSManager
): Future[void] {.base, async: (raises: [CancelledError]).} =
  trace "AutoTLS stop"
  if self.managerFut.isNil:
    warn "AutoTLS manager not running"
    return

  await self.managerFut.cancelAndWait()
  self.managerFut = nil

  if self.acmeClient.isSome:
    await self.acmeClient.get.close()

  await self.brokerClient.close()

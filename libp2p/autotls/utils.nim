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

import net, strutils
from times import DateTime, toTime, toUnix

import chronos, stew/base36, chronicles

import
  ./acme/client,
  ../errors,
  ../peerid,
  ../multihash,
  ../cid,
  ../multicodec,
  ../nameresolving/dnsresolver

const
  DefaultDnsRetries = 10
  DefaultDnsRetryTime = 1.seconds

type AutoTLSError* = object of LPError

proc checkedGetPrimaryIPAddr(): IpAddress {.raises: [AutoTLSError].} =
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

proc getPublicIPADdress*(): IpAddress {.raises: [AutoTLSError].} =
  try:
    let ip = checkedGetPrimaryIPAddr()
    if not ip.isIPv4():
      raise newException(AutoTLSError, "Host does not have an IPv4 address")
    if not ip.isPublic():
      raise newException(AutoTLSError, "Host does not have a public IPv4 address")
    return ip
  except AutoTLSError as exc:
    raise exc
  except CatchableError as exc:
    raise newException(
      AutoTLSError, "Unexpected error while getting primary IP address for host", exc
    )

proc asMoment*(dt: DateTime): Moment =
  let unixTime: int64 = dt.toTime.toUnix
  return Moment.init(unixTime, Second)

proc encodePeerId*(peerId: PeerId): string {.raises: [AutoTLSError].} =
  var mh: MultiHash
  let decodeResult = MultiHash.decode(peerId.data, mh)
  if decodeResult.isErr() or decodeResult.get() == -1:
    raise
      newException(AutoTLSError, "Failed to decode PeerId: invalid multihash format")

  let cidResult = Cid.init(CIDv1, multiCodec("libp2p-key"), mh)
  if cidResult.isErr():
    raise newException(AutoTLSError, "Failed to initialize CID from multihash")

  return Base36.encode(cidResult.get().data.buffer)

proc checkDNSRecords*(
    dnsResolver: DnsResolver,
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
    txt = await dnsResolver.resolveTxt(acmeChalDomain)
    try:
      ip4 = await dnsResolver.resolveIp(ip4Domain, 0.Port)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      error "Failed to resolve IP", description = exc.msg # retry
  if txt.len > 0 and txt[0] == keyAuth and ip4.len > 0:
    return true
  await sleepAsync(DefaultDnsRetryTime)

  return false

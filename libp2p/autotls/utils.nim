# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH
{.push raises: [].}

import chronos, chronicles, strutils
import stew/base36
import
  ../errors,
  ../peerid,
  ../multihash,
  ../cid,
  ../multicodec,
  ../nameresolving/nameresolver,
  ./acme/client

logScope:
  topics = "libp2p utils"

type AutoTLSError* = object of LPError

const
  DefaultDnsRetries = 3
  DefaultDnsRetryTime = 1.seconds

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

func dnsLabel(ipAddress: IpAddress): string =
  ## p2p-forge label: 100.10.10.3 gives 100-10-10-3, ::1 gives 0--1 (RFC 1123).
  if ipAddress.family == IpAddressFamily.IPv4:
    return ($ipAddress).replace('.', '-')

  var label = ($ipAddress).replace(':', '-')
  if label.startsWith('-'):
    label = "0" & label
  if label.endsWith('-'):
    label = label & "0"
  label

proc checkDNSRecords*(
    nameResolver: NameResolver,
    ipAddress: IpAddress,
    baseDomain: api.Domain,
    keyAuth: KeyAuthorization,
    retries: int = DefaultDnsRetries,
    retryTime: Duration = DefaultDnsRetryTime,
): Future[bool] {.async: (raises: [AutoTLSError, CancelledError]).} =
  let acmeChalDomain = api.Domain("_acme-challenge." & baseDomain)
  let ipDomain = api.Domain(ipAddress.dnsLabel() & "." & baseDomain)
  debug "Waiting for DNS record to be set", ip = ipDomain, acme = acmeChalDomain

  for attempt in 0 .. retries:
    if attempt > 0:
      await sleepAsync(retryTime)

    let txt = await nameResolver.resolveTxt(acmeChalDomain)
    var resolvedIps: seq[TransportAddress]
    try:
      resolvedIps = await nameResolver.resolveIp(ipDomain, 0.Port)
    except CancelledError as exc:
      raise exc
    except CatchableError as exc:
      debug "Failed to resolve IP", description = exc.msg # retry

    if txt.len > 0 and txt[0] == keyAuth and resolvedIps.len > 0:
      return true

  return false

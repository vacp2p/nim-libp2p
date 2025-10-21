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

import chronos, chronicles
import ../errors

logScope:
  topics = "libp2p utils"

const
  DefaultDnsRetries = 3
  DefaultDnsRetryTime = 1.seconds

type AutoTLSError* = object of LPError

when defined(libp2p_autotls_support):
  import strutils
  from times import DateTime, toTime, toUnix
  import stew/base36
  import
    ../peerid,
    ../multihash,
    ../cid,
    ../multicodec,
    ../nameresolving/nameresolver,
    ./acme/client

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
      nameResolver: NameResolver,
      ipAddress: IpAddress,
      baseDomain: api.Domain,
      keyAuth: KeyAuthorization,
      retries: int = DefaultDnsRetries,
      retryTime: Duration = DefaultDnsRetryTime,
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
      txt = await nameResolver.resolveTxt(acmeChalDomain)
      try:
        ip4 = await nameResolver.resolveIp(ip4Domain, 0.Port)
      except CancelledError as exc:
        raise exc
      except CatchableError as exc:
        error "Failed to resolve IP", description = exc.msg # retry
    if txt.len > 0 and txt[0] == keyAuth and ip4.len > 0:
      return true
    await sleepAsync(retryTime)

    return false

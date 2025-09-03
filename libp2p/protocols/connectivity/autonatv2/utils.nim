{.push raises: [].}

import results, strutils
import chronos
import
  ../../protocol,
  ../../../switch,
  ../../../multiaddress,
  ../../../multicodec,
  ../../../peerid,
  ../../../protobuf/minprotobuf,
  ../autonat/service,
  ./types

proc ipAddrMatches*(
    observedIPAddr: MultiAddress, reqAddrs: seq[MultiAddress], ip4: bool = true
): bool =
  ## Checks if at least one of the requests' addresses
  ## has the same IP address of observedIPAddr

  let ipType =
    if ip4:
      multiCodec("ip4")
    else:
      multiCodec("ip6")

  let observedIPAddr = observedIPAddr.getPart(ipType).valueOr:
    return false

  for addr in reqAddrs:
    addr[0].withValue(ipAddr):
      if ipAddr == observedIPAddr:
        return true
  return false

proc ipSupport*(s: Switch): (bool, bool) =
  ## Returns ipv4 and ipv6 support status of a switch

  var ipv4 = false
  var ipv6 = false

  for addrs in s.peerInfo.listenAddrs:
    addrs[0].withValue(addrIp):
      if IP4.match(addrIp):
        ipv4 = true
      elif IP6.match(addrIp):
        ipv6 = true

  (ipv4, ipv6)

proc isPrivateIP*(ip: string): bool {.raises: [ValueError].} =
  ip.startsWith("10.") or
    (ip.startsWith("172.") and parseInt(ip.split(".")[1]) in 16 .. 31) or
    ip.startsWith("192.168.") or ip.startsWith("127.") or ip.startsWith("169.254.")

proc asNetworkReachability*(self: DialResponse): NetworkReachability =
  if self.status == EInternalError:
    return Unknown
  if self.status == ERequestRejected:
    return Unknown
  if self.status == EDialRefused:
    return Unknown

  # if got here it means a dial was attempted
  let dialStatus = self.dialStatus.valueOr:
    return Unknown
  if dialStatus == Unused:
    return Unknown
  if dialStatus == EDialError:
    return NotReachable
  if dialStatus == EDialBackError:
    return NotReachable
  return Reachable

proc asAutonatV2Response*(
    self: DialResponse, testAddrs: seq[MultiAddress]
): AutonatV2Response =
  let addrIdx = self.addrIdx.valueOr:
    return AutonatV2Response(
      reachability: self.asNetworkReachability(),
      dialResp: self,
      addrs: Opt.none(MultiAddress),
    )
  AutonatV2Response(
    reachability: self.asNetworkReachability(),
    dialResp: self,
    addrs: Opt.some(testAddrs[addrIdx]),
  )

proc areAddrsConsistent*(addrA, addrB: MultiAddress): bool =
  ## Checks if two multiaddresses have the same protocol stack.
  let protosA = addrA.protocols().get()
  let protosB = addrB.protocols().get()
  if protosA.len != protosB.len:
    return false

  for idx in 0 ..< protosA.len:
    let protoA = protosA[idx]
    let protoB = protosB[idx]

    if protoA != protoB:
      if idx == 0:
        # allow DNS ↔ IP at the first component
        if protoB == multiCodec("dns") or protoB == multiCodec("dnsaddr"):
          if not (protoA == multiCodec("ip4") or protoA == multiCodec("ip6")):
            return false
        elif protoB == multiCodec("dns4"):
          if protoA != multiCodec("ip4"):
            return false
        elif protoB == multiCodec("dns6"):
          if protoA != multiCodec("ip6"):
            return false
        else:
          return false
      else:
        return false

  true

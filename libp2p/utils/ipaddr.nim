import net, strutils

import ../switch, ../multiaddress, ../multicodec

proc isIPv4*(ip: IpAddress): bool =
  ip.family == IpAddressFamily.IPv4

proc isIPv6*(ip: IpAddress): bool =
  ip.family == IpAddressFamily.IPv6

proc isPrivate*(ip: string): bool {.raises: [ValueError].} =
  ip.startsWith("10.") or
    (ip.startsWith("172.") and parseInt(ip.split(".")[1]) in 16 .. 31) or
    ip.startsWith("192.168.") or ip.startsWith("127.") or ip.startsWith("169.254.")

proc isPrivate*(ip: IpAddress): bool {.raises: [ValueError].} =
  isPrivate($ip)

proc isPublic*(ip: string): bool {.raises: [ValueError].} =
  not isPrivate(ip)

proc isPublic*(ip: IpAddress): bool {.raises: [ValueError].} =
  isPublic($ip)

proc getPublicIPAddress*(): IpAddress {.raises: [OSError, ValueError].} =
  let ip =
    try:
      getPrimaryIPAddr()
    except OSError as exc:
      raise exc
    except ValueError as exc:
      raise exc
    except Exception as exc:
      raise newException(OSError, "Could not get primary IP address")
  if not ip.isIPv4():
    raise newException(ValueError, "Host does not have an IPv4 address")
  if not ip.isPublic():
    raise newException(ValueError, "Host does not have a public IPv4 address")
  ip

proc ipAddrMatches*(
    lookup: MultiAddress, addrs: seq[MultiAddress], ip4: bool = true
): bool =
  ## Checks ``lookup``'s IP is in any of addrs

  let ipType =
    if ip4:
      multiCodec("ip4")
    else:
      multiCodec("ip6")

  let lookup = lookup.getPart(ipType).valueOr:
    return false

  for ma in addrs:
    ma[0].withValue(ipAddr):
      if ipAddr == lookup:
        return true
  false

proc ipSupport*(addrs: seq[MultiAddress]): (bool, bool) =
  ## Returns ipv4 and ipv6 support status of a list of MultiAddresses

  var ipv4 = false
  var ipv6 = false

  for ma in addrs:
    ma[0].withValue(addrIp):
      if IP4.match(addrIp):
        ipv4 = true
      elif IP6.match(addrIp):
        ipv6 = true

  (ipv4, ipv6)

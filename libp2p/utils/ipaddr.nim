# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import net, chronicles, strutils

import ../switch, ../multiaddress, ../multicodec

proc isIPv4*(ip: IpAddress): bool =
  ip.family == IpAddressFamily.IPv4

proc isIPv6*(ip: IpAddress): bool =
  ip.family == IpAddressFamily.IPv6

proc isPrivate*(ip: string): bool {.raises: [].} =
  try:
    return
      ip.startsWith("10.") or
      (ip.startsWith("172.") and parseInt(ip.split(".")[1]) in 16 .. 31) or
      ip.startsWith("192.168.") or ip.startsWith("127.") or ip.startsWith("169.254.")
  except ValueError:
    return false

proc isPrivate*(ip: IpAddress): bool {.raises: [].} =
  isPrivate($ip)

proc isPublic*(ip: string): bool {.raises: [].} =
  not isPrivate(ip)

proc isPublic*(ip: IpAddress): bool {.raises: [].} =
  isPublic($ip)

proc hasPublicIPAddress*(): bool {.raises: [].} =
  let ip =
    try:
      getPrimaryIPAddr()
    except CatchableError as e:
      error "Unable to get primary ip address", description = e.msg
      return false
    except Exception as e:
      error "Unable to get primary ip address", description = e.msg
      return false
  debug "Primary IP address", ip = ip, isIPv4 = ip.isIPv4(), isPublic = ip.isPublic()

  return ip.isIPv4() and ip.isPublic()

proc getPublicIPAddress*(): IpAddress {.raises: [OSError, ValueError].} =
  if not hasPublicIPAddress():
    raise newException(ValueError, "Host does not have a public IPv4 address")
  try:
    return getPrimaryIPAddr()
  except Exception as e:
    raise newException(OSError, e.msg)

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

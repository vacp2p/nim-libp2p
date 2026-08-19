# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import net, chronicles, strutils, results
import chronos

import ../multiaddress, ../multicodec

const RouteProbes = [parseIpAddress("8.8.8.8"), parseIpAddress("2001:4860:4860::8888")]

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

proc isGlobalIP*(ip: IpAddress): bool {.raises: [].} =
  ## Unlike ``isPublic``, this is family-aware and also rejects private IPv6.
  initTAddress(ip, Port(0)).isGlobal()

proc primaryIPAddrTo(probe: IpAddress): Opt[IpAddress] {.raises: [].} =
  ## Source address the routing table picks for ``probe``. No traffic is sent.
  try:
    Opt.some(getPrimaryIPAddr(probe))
  except CatchableError as e:
    debug "Unable to get primary ip address", probe, description = e.msg
    Opt.none(IpAddress)
  except Defect as e:
    raise e
  except Exception as e: # on windows getPrimaryIPAddr has untracked effects
    debug "Unable to get primary ip address", probe, description = e.msg
    Opt.none(IpAddress)

func firstGlobalIP*(candidates: openArray[IpAddress]): Opt[IpAddress] =
  for ip in candidates:
    if ip.isGlobalIP():
      return Opt.some(ip)
  Opt.none(IpAddress)

proc getPublicIPAddress*(): Opt[IpAddress] {.raises: [].} =
  ## Public address of the host, IPv4 first. A v6-only host reaches the v6 probe only.
  var candidates: seq[IpAddress]
  for probe in RouteProbes:
    let ip = primaryIPAddrTo(probe).valueOr:
      continue
    debug "Primary IP address", ip, global = ip.isGlobalIP()
    candidates.add(ip)
  firstGlobalIP(candidates)

func ipAddrMatches*(lookup: MultiAddress, addrs: openArray[MultiAddress]): bool =
  ## Returns true when the ip4 or ip6 component of ``lookup`` equals that of any addr

  let lookupIp = lookup.getPart(multiCodec("ip4")).valueOr:
    lookup.getPart(multiCodec("ip6")).valueOr:
      return false

  for ma in addrs:
    ma[0].withValue(ipAddr):
      if ipAddr == lookupIp:
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

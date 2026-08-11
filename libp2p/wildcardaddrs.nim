# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/sequtils
import chronos, chronos/transports/[osnet, ipnet]
import multiaddress

type NetworkInterfaceProvider* =
  proc(addrFamily: AddressFamily): seq[InterfaceAddress] {.gcsafe, raises: [].}

func isLoopbackOrUp(networkInterface: NetworkInterface): bool =
  networkInterface.ifType == IfSoftwareLoopback or networkInterface.state == StatusUp

proc getAddresses*(addrFamily: AddressFamily): seq[InterfaceAddress] =
  ## The addresses of every loopback or running interface of `addrFamily`.
  let interfaces = getInterfaces().filterIt(it.isLoopbackOrUp())
  concat(interfaces.mapIt(it.addresses)).filterIt(it.host.family == addrFamily)

proc isWildcardIp(ip: IpAddress): bool =
  case ip.family
  of IpAddressFamily.IPv4:
    ip.address_v4 == AnyAddress.address_v4
  of IpAddressFamily.IPv6:
    ip.address_v6 == AnyAddress6.address_v6

proc expandWildcardAddresses*(
    networkInterfaceProvider: NetworkInterfaceProvider, listenAddrs: seq[MultiAddress]
): seq[MultiAddress] =
  ## Expands each bound wildcard address (``0.0.0.0`` / ``::``) into one address
  ## per matching network interface. The other addresses pass through unchanged.
  ## The transport, the port, and any suffix (e.g. ``/quic-v1``, ``/ws``,
  ## ``/wss``, ``/tls/ws``) are preserved on the expanded copies.
  var addresses: seq[MultiAddress]
  for listenAddr in listenAddrs:
    let listenIp = listenAddr.getIp().valueOr:
      addresses.add(listenAddr)
      continue

    if not isWildcardIp(listenIp):
      addresses.add(listenAddr)
      continue

    let families =
      case listenIp.family
      of IpAddressFamily.IPv4:
        @[AddressFamily.IPv4]
      of IpAddressFamily.IPv6:
        # IPv6 dual stack: also expand to IPv4 interfaces
        @[AddressFamily.IPv6, AddressFamily.IPv4]

    for family in families:
      for ifaddr in networkInterfaceProvider(family):
        listenAddr.replaceIp(ifaddr.host.toIpAddress()).withValue(remapped):
          addresses.add(remapped)
  addresses

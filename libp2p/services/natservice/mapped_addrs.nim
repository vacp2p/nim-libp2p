# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net, sequtils]
import results
import ../../[multiaddress, multicodec]
import ./port_mapper

export port_mapper

proc explicitIpMapped*(
    listenAddrs: seq[MultiAddress], explicitIp: IpAddress
): seq[MultiAddress] =
  ## Swap the IP in each listen address to ``explicitIp``. Drops addresses
  ## without an IP or with a mismatching family. Deduplicates.
  var addrs: seq[MultiAddress]
  for listenAddr in listenAddrs:
    let ip = listenAddr.getIp().valueOr:
      continue
    if ip.family != explicitIp.family:
      continue
    let remapped = listenAddr.replaceIp(explicitIp).valueOr:
      continue
    if remapped notin addrs:
      addrs.add(remapped)
  addrs

proc isLoopback(ip: IpAddress): bool =
  ## True for 127.0.0.0/8 (IPv4) or ::1 (IPv6).
  case ip.family
  of IpAddressFamily.IPv4:
    ip.address_v4[0] == 127'u8
  of IpAddressFamily.IPv6:
    ip.address_v6 == [0'u8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]

proc portProtocol(ma: MultiAddress): Opt[NATProtocol] =
  ## Return the first /tcp or /udp protocol in ``ma``.
  if ma.contains(multiCodec("tcp")).get(false):
    Opt.some(NATProtoTcp)
  elif ma.contains(multiCodec("udp")).get(false):
    Opt.some(NATProtoUdp)
  else:
    Opt.none(NATProtocol)

proc findMappingFor(
    listenAddr: MultiAddress, mappings: seq[PortMapping]
): Opt[PortMapping] =
  ## Find the mapping matching the port + protocol of ``listenAddr``.
  let
    port = listenAddr.getPort().valueOr:
      return Opt.none(PortMapping)
    protocol = listenAddr.portProtocol().valueOr:
      return Opt.none(PortMapping)
  for m in mappings:
    if m.internalPort == port and m.protocol == protocol:
      return Opt.some(m)
  Opt.none(PortMapping)

proc gatewayMapped*(
    listenAddrs: seq[MultiAddress], externalIp: IpAddress, mappings: seq[PortMapping]
): seq[MultiAddress] =
  ## Swap IP and port in each listen address using ``externalIp`` and its
  ## matching gateway mapping. Drops unmatched or mismatched-family addresses.
  var announces: seq[MultiAddress]
  for listenAddr in listenAddrs:
    if not listenAddr.hasIp() or not listenAddr.hasPort():
      continue
    let
      mapping = findMappingFor(listenAddr, mappings).valueOr:
        continue
      ip = listenAddr.getIp().get()
    if ip.family != externalIp.family:
      continue
    let announced = listenAddr.replaceIp(externalIp).valueOr:
      continue
    let withPort = announced.replacePort(mapping.externalPort).valueOr:
      continue
    if withPort notin announces:
      announces.add(withPort)
  announces

proc collectInternalPorts*(listenAddrs: seq[MultiAddress]): seq[PortMapping] =
  ## Unique (port, protocol) pairs across ``listenAddrs``, with external port
  ## initially equal to the internal port (gateway fills it in later).
  var seen: seq[PortMapping]
  for listenAddr in listenAddrs:
    # A gateway can't map a host-local port, so don't bother requesting it.
    let ip = listenAddr.getIp()
    if ip.isSome and ip.get.isLoopback:
      continue
    let
      port = listenAddr.getPort().valueOr:
        continue
      protocol = listenAddr.portProtocol().valueOr:
        continue
    if seen.anyIt(it.internalPort == port and it.protocol == protocol):
      continue
    seen.add(PortMapping(internalPort: port, externalPort: port, protocol: protocol))
  seen

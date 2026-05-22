# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/net
import results
import ../../[multiaddress, multicodec]
import ./port_mapper

export port_mapper

proc explicitIpMapped*(
    listenAddrs: seq[MultiAddress], explicitIp: IpAddress
): seq[MultiAddress] =
  ## For each listen address that carries an IP component matching the family
  ## of ``explicitIp``, emit a copy with the IP swapped to ``explicitIp``.
  ## Transport, port, and any suffix (e.g. ``/quic-v1``, ``/ws``, ``/wss``,
  ## ``/tls/ws``) are preserved. Addresses without an IP component, or with a
  ## mismatching family, are dropped. Duplicates (which can arise when the
  ## wildcard resolver expands a wildcard listen addr across multiple
  ## interfaces sharing the same port) are collapsed.
  var addrs: seq[MultiAddress]
  for listenAddr in listenAddrs:
    let ip = listenAddr.getIp().valueOr:
      continue
    if ip.family != explicitIp.family:
      continue
    listenAddr.replaceIp(explicitIp).withValue(remapped):
      if remapped notin addrs:
        addrs.add(remapped)
  addrs

proc extractPort(
    ma: MultiAddress
): tuple[port: Port, protocol: NATProtocol, present: bool] =
  ## Walk the multiaddress and return the first /tcp or /udp port + protocol.
  ## The /quic, /quic-v1 etc. suffixes (which sit *after* /udp in the address)
  ## do not affect what we map: NAT-PMP/UPnP only know about TCP/UDP.
  let tcpCodec = multiCodec("tcp")
  let udpCodec = multiCodec("udp")
  for part in ma.items:
    let p = part.valueOr:
      continue
    let code = p.protoCode().valueOr:
      continue
    if code == tcpCodec or code == udpCodec:
      let portBytes = p.protoArgument().valueOr:
        continue
      if portBytes.len != 2:
        continue
      let port = Port((uint16(portBytes[0]) shl 8) or uint16(portBytes[1]))
      let proto = if code == tcpCodec: NATProtoTcp else: NATProtoUdp
      return (port, proto, true)
  (Port(0), NATProtoTcp, false)

proc mappedAnnouncements*(
    listenAddrs: seq[MultiAddress], externalIp: IpAddress, mappings: seq[PortMapping]
): seq[MultiAddress] =
  ## For each listen address, find a matching ``PortMapping`` (by internal
  ## port + protocol) and emit a multiaddr with the IP swapped to
  ## ``externalIp`` and the port swapped to ``mapping.externalPort``. Listen
  ## addresses without an IP component or without a matching mapping are
  ## dropped. Duplicates are collapsed.
  var announces: seq[MultiAddress]
  for listenAddr in listenAddrs:
    let
      (internalPort, proto, present) = extractPort(listenAddr)
      ip = listenAddr.getIp().valueOr:
        continue
    if not present:
      continue
    if ip.family != externalIp.family:
      continue
    var matched: Opt[PortMapping]
    for m in mappings:
      if m.internalPort == internalPort and m.protocol == proto:
        matched = Opt.some(m)
        break
    let mapping = matched.valueOr:
      continue
    # Build the announced address: swap the IP component and the tcp/udp port.
    let
      ip4 = multiCodec("ip4")
      ip6 = multiCodec("ip6")
      newIpMa =
        case externalIp.family
        of IpAddressFamily.IPv4:
          MultiAddress.init(ip4, externalIp.address_v4).valueOr:
            continue
        of IpAddressFamily.IPv6:
          MultiAddress.init(ip6, externalIp.address_v6).valueOr:
            continue
      portCodec =
        if proto == NATProtoTcp:
          multiCodec("tcp")
        else:
          multiCodec("udp")
      newPortMa = MultiAddress.init(portCodec, int(mapping.externalPort)).valueOr:
        continue
    var rebuilt = MultiAddress.init()
    var replacedIp = false
    var replacedPort = false
    var appendOk = true
    for part in listenAddr.items:
      let p = part.valueOr:
        appendOk = false
        break
      let code = p.protoCode().valueOr:
        appendOk = false
        break
      if not replacedIp and (code == ip4 or code == ip6):
        if rebuilt.append(newIpMa).isErr:
          appendOk = false
          break
        replacedIp = true
      elif not replacedPort and (code == multiCodec("tcp") or code == multiCodec("udp")):
        if rebuilt.append(newPortMa).isErr:
          appendOk = false
          break
        replacedPort = true
      else:
        if rebuilt.append(p).isErr:
          appendOk = false
          break
    if not appendOk or not replacedIp or not replacedPort:
      continue
    if rebuilt notin announces:
      announces.add(rebuilt)
  announces

proc collectInternalPorts*(listenAddrs: seq[MultiAddress]): seq[PortMapping] =
  ## Deduplicate (port, protocol) pairs across all listen addresses, with the
  ## external port initially set equal to the internal port. The external port
  ## is updated by the gateway response in NATService.acquireMappings.
  var seen: seq[PortMapping]
  for listenAddr in listenAddrs:
    let (port, proto, present) = extractPort(listenAddr)
    if not present:
      continue
    let candidate = PortMapping(internalPort: port, externalPort: port, protocol: proto)
    var dup = false
    for m in seen:
      if m.internalPort == port and m.protocol == proto:
        dup = true
        break
    if not dup:
      seen.add(candidate)
  seen

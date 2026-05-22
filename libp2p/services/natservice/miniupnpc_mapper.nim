# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/net
import chronos, results
import nat_traversal/miniupnpc
import ./port_mapper

export port_mapper

type MiniupnpcMapper* = ref object of NATPortMapper
  upnp: Miniupnp
  discovered: bool

proc newMiniupnpcMapper*(): NATPortMapper {.raises: [NATMapperError].} =
  let m = MiniupnpcMapper(upnp: newMiniupnp())
  m.upnp.discoverDelay = 200
  m

proc ensureDiscovered(self: MiniupnpcMapper): Result[void, string] =
  if self.discovered:
    return ok()
  self.upnp.discover().isOkOr:
    return err($error)
  case self.upnp.selectIGD()
  of IGDNotFound:
    return err("UPnP: Internet Gateway Device not found")
  of NotAnIGD:
    return err("UPnP: device found is not an IGD")
  of IGDFound, IGDIpNotRoutable, IGDNotConnected:
    # NotRoutable/NotConnected are best-effort — the gateway may still accept
    # the mapping. Match the behaviour in nim-eth's nat.nim.
    self.discovered = true
    ok()

method discoverExternalIp*(self: MiniupnpcMapper): Result[IpAddress, string] =
  ?self.ensureDiscovered()
  let ipStr = self.upnp.externalIPAddress().valueOr:
    return err($error)
  try:
    ok(parseIpAddress(ipStr))
  except ValueError as e:
    err("UPnP: unparsable external IP '" & ipStr & "': " & e.msg)

method addMapping*(
    self: MiniupnpcMapper,
    internalPort: Port,
    protocol: NATProtocol,
    leaseDuration: Duration,
    description: string,
): Result[Port, string] =
  ?self.ensureDiscovered()
  let proto =
    case protocol
    of NATProtoTcp: UPNPProtocol.TCP
    of NATProtoUdp: UPNPProtocol.UDP
  let leaseSecs = leaseDuration.seconds
  self.upnp.addPortMapping(
    externalPort = $int(internalPort),
    protocol = proto,
    internalHost = self.upnp.lanAddr,
    internalPort = $int(internalPort),
    desc = description,
    leaseDuration = int(leaseSecs),
  ).isOkOr:
    return err($error)
  ok(internalPort)

method deleteMapping*(
    self: MiniupnpcMapper, externalPort: Port, internalPort: Port, protocol: NATProtocol
): Result[void, string] =
  if not self.discovered:
    return ok()
  let proto =
    case protocol
    of NATProtoTcp: UPNPProtocol.TCP
    of NATProtoUdp: UPNPProtocol.UDP
  self.upnp.deletePortMapping(externalPort = $int(externalPort), protocol = proto).isOkOr:
    return err($error)
  ok()

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/net
import chronos, results
import nat_traversal/natpmp
import ./port_mapper

export port_mapper

type NatPmpMapper* = ref object of NATPortMapper
  npmp: NatPmp
  initialized: bool

proc newNatPmpMapper*(): NATPortMapper {.raises: [NATMapperError].} =
  NatPmpMapper(npmp: newNatPmp())

proc ensureInitialized(self: NatPmpMapper): Result[void, string] =
  if self.initialized:
    return ok()
  self.npmp.init().isOkOr:
    return err($error)
  self.initialized = true
  ok()

method discoverExternalIp*(self: NatPmpMapper): Result[IpAddress, string] =
  ?self.ensureInitialized()
  let ipStr = self.npmp.externalIPAddress().valueOr:
    return err(error)
  try:
    ok(parseIpAddress($ipStr))
  except ValueError as e:
    err("NAT-PMP: unparsable external IP '" & $ipStr & "': " & e.msg)

method addMapping*(
    self: NatPmpMapper,
    internalPort: Port,
    protocol: NATProtocol,
    leaseDuration: Duration,
    description: string,
): Result[Port, string] =
  ?self.ensureInitialized()
  let proto =
    case protocol
    of NATProtoTcp: NatPmpProtocol.TCP
    of NATProtoUdp: NatPmpProtocol.UDP
  let extPort = self.npmp.addPortMapping(
    eport = cushort(internalPort),
    iport = cushort(internalPort),
    protocol = proto,
    lifetime = culong(leaseDuration.seconds),
  ).valueOr:
    return err(error)
  ok(Port(extPort))

method deleteMapping*(
    self: NatPmpMapper, externalPort: Port, internalPort: Port, protocol: NATProtocol
): Result[void, string] =
  if not self.initialized:
    return ok()
  let proto =
    case protocol
    of NATProtoTcp: NatPmpProtocol.TCP
    of NATProtoUdp: NatPmpProtocol.UDP
  self.npmp.deletePortMapping(
    eport = cushort(externalPort), iport = cushort(internalPort), protocol = proto
  ).isOkOr:
    return err(error)
  ok()

method close*(self: NatPmpMapper) =
  if self.initialized:
    self.npmp.close()
    self.initialized = false

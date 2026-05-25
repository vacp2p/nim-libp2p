# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/net
import chronos, results

type
  NATProtocol* = enum
    NATProtoTcp = "TCP"
    NATProtoUdp = "UDP"

  PortMapping* = object
    internalPort*: Port
    externalPort*: Port
    protocol*: NATProtocol

  NATMapperError* = object of CatchableError

  NATPortMapper* = ref object of RootObj
    ## Abstract backend that wraps a single port-mapping protocol (UPnP or
    ## NAT-PMP). Subclassed for production (miniupnpc / libnatpmp) and for
    ## tests (in-memory fakes). Method bodies block the calling thread and
    ## must not be invoked on the chronos event loop without yielding.

method discoverExternalIp*(
    m: NATPortMapper
): Result[IpAddress, string] {.base, gcsafe, raises: [].} =
  raiseAssert "[NATPortMapper.discoverExternalIp] abstract method not implemented"

method addMapping*(
    m: NATPortMapper,
    internalPort: Port,
    protocol: NATProtocol,
    leaseDuration: Duration,
    description: string,
): Result[Port, string] {.base, gcsafe, raises: [].} =
  raiseAssert "[NATPortMapper.addMapping] abstract method not implemented"

method deleteMapping*(
    m: NATPortMapper, externalPort: Port, internalPort: Port, protocol: NATProtocol
): Result[void, string] {.base, gcsafe, raises: [].} =
  raiseAssert "[NATPortMapper.deleteMapping] abstract method not implemented"

method close*(m: NATPortMapper) {.base, gcsafe, raises: [].} =
  discard

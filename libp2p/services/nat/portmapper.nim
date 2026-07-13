# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/net
import chronos, results

type
  MapProto* = enum
    mpTcp
    mpUdp

  MappedPort* = object
    ## Outcome of a successful mapping: the external address the NAT device
    ## assigned. libplum returns the external host and port together with the
    ## mapping, so there is a single `map` call rather than the old
    ## discover-external-IP-then-map split.
    externalIp*: IpAddress
    externalPort*: Port

  PortMapper* = ref object of RootObj
    ## Abstract base for a NAT port-mapping client (libplum-backed / mock).
    ## All operations are async: the libplum backend hands the request to the
    ## library's internal thread and awaits its completion.

method map*(
    self: PortMapper, internalPort: Port, externalPort: Port, proto: MapProto
): Future[Result[MappedPort, string]] {.
    base, async: (raises: [CancelledError]), gcsafe
.} =
  raiseAssert "PortMapper.map not implemented"

method unmap*(
    self: PortMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  raiseAssert "PortMapper.unmap not implemented"

method close*(self: PortMapper) {.base, async: (raises: []), gcsafe.} =
  discard

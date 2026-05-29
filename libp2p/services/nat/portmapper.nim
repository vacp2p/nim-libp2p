# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net]
import chronos, results

type
  MapProto* = enum
    mpTcp
    mpUdp

  PortMapper* = ref object of RootObj
    ## Abstract base for a NAT port-mapping client (UPnP / NAT-PMP / mock).
    ## All operations are async because real implementations dispatch the
    ## underlying sync C calls to a dedicated worker thread.

method discover*(
    self: PortMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  raiseAssert "PortMapper.discover not implemented"

method map*(
    self: PortMapper,
    internalPort: Port,
    externalPort: Port,
    proto: MapProto,
    lease: uint32,
): Future[Result[Port, string]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  raiseAssert "PortMapper.map not implemented"

method unmap*(
    self: PortMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.base, async: (raises: [CancelledError]), gcsafe.} =
  raiseAssert "PortMapper.unmap not implemented"

method close*(self: PortMapper) {.base, gcsafe, raises: [].} =
  discard

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## NAT port mapper backed by libplum (PCP / NAT-PMP / UPnP-IGD).
##
## libplum owns a single process-wide client with its own internal thread that
## discovers the gateway, selects a working protocol, and keeps mappings
## refreshed on its own — so there is no per-mapping lease and no refresh loop
## on our side. The C `plum_init`/`plum_cleanup` pair is a global singleton
## (a second `plum_init` fails while a client is live), so this module
## ref-counts init across every live `PlumMapper` and keeps the protocol filter
## of the first mapper that initialized it.
##
## Precondition: every `PlumMapper` is created and closed from the same chronos
## event-loop thread. The ref-count and active-filter globals below are plain
## (unsynchronized) vars, so driving mappers from multiple threads would race
## them and double-init libplum.

{.push raises: [].}

import std/[net, tables]
import chronos, chronicles, results
import libplum/plum
import ./portmapper

export ProtocolFilter

logScope:
  topics = "libp2p natservice plum"

const
  DefaultDiscoverTimeout* = 10.seconds
  DefaultMappingTimeout* = 10.seconds

type
  MappingKey = tuple[externalPort: uint16, proto: MapProto]

  PlumMapper* = ref object of PortMapper
    filter: ProtocolFilter
    closed: bool
    mappings: Table[MappingKey, cint]
      ## (externalPort, proto) -> libplum mapping id, recorded on a successful
      ## map() so unmap()/close() can find the opaque handle to destroy.

var
  plumRefCount = 0
  plumActiveFilter = ProtocolFilter.Any

func toPlumProto(p: MapProto): PlumProtocol =
  case p
  of mpTcp: PlumProtocol.TCP
  of mpUdp: PlumProtocol.UDP

func toMs(d: Duration): int32 =
  int32(d.milliseconds.clamp(0'i64, int64(high(int32))))

proc acquirePlum(
    filter: ProtocolFilter, discoverTimeout, mappingTimeout: Duration
): Result[void, string] =
  if plumRefCount == 0:
    plum.init(
      logLevel = PlumLogLevel.None,
      discoverTimeout = toMs(discoverTimeout),
      mappingTimeout = toMs(mappingTimeout),
      protocol = filter,
    ).isOkOr:
      return err(error)
    plumActiveFilter = filter
  elif filter != plumActiveFilter:
    warn "libplum already initialized with a different protocol filter; reusing existing",
      requested = filter, active = plumActiveFilter
  inc plumRefCount
  ok()

proc releasePlum() =
  if plumRefCount == 0:
    return
  dec plumRefCount
  if plumRefCount == 0:
    plum.cleanup().isOkOr:
      warn "plum_cleanup failed", err = error

proc new*(
    T: typedesc[PlumMapper],
    filter = ProtocolFilter.Any,
    discoverTimeout = DefaultDiscoverTimeout,
    mappingTimeout = DefaultMappingTimeout,
): Result[T, string] =
  ?acquirePlum(filter, discoverTimeout, mappingTimeout)
  ok(PlumMapper(filter: filter))

method map*(
    self: PlumMapper, internalPort: Port, externalPort: Port, proto: MapProto
): Future[Result[MappedPort, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if self.closed:
    return err("PlumMapper closed")

  let res = ?await createMapping(
    protocol = toPlumProto(proto),
    internalPort = internalPort.uint16,
    externalPort = externalPort.uint16,
  )

  # close() may have run during the await above and torn libplum down; drop the
  # mapping we just created rather than recording an id for a dead handle.
  if self.closed:
    destroyMapping(res.id)
    return err("PlumMapper closed")

  let externalIp =
    try:
      parseIpAddress(res.mapping.externalHost)
    except ValueError as e:
      destroyMapping(res.id)
      return err(
        "plum: cannot parse external host '" & res.mapping.externalHost & "': " & e.msg
      )

  self.mappings[(res.mapping.externalPort, proto)] = res.id
  ok(MappedPort(externalIp: externalIp, externalPort: Port(res.mapping.externalPort)))

method unmap*(
    self: PlumMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let key: MappingKey = (externalPort.uint16, proto)
  # libplum ids are non-negative; -1 marks "no mapping recorded".
  let id = self.mappings.getOrDefault(key, cint(-1))
  if id < 0:
    return err("plum unmap: no known mapping for external port " & $externalPort.uint16)

  destroyMapping(id)
  self.mappings.del(key)
  ok()

method close*(self: PlumMapper) {.async: (raises: []), gcsafe.} =
  if self.closed:
    return
  self.closed = true

  for id in self.mappings.values():
    destroyMapping(id)
  self.mappings.clear()
  releasePlum()

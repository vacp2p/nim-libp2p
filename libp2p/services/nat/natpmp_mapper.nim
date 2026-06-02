# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## NAT-PMP port mapper. Mirrors the worker-thread structure of upnp_mapper.nim
## around the `nat_traversal/natpmp` sync bindings.

{.push raises: [].}

import std/[atomics, net, tables]
import chronos, chronos/threadsync, chronicles, results
import nat_traversal/natpmp
import ./portmapper

logScope:
  topics = "libp2p natservice natpmp"

type
  NatPmpReqKind = enum
    nrDiscover
    nrMap
    nrUnmap
    nrShutdown

  NatPmpRequest = object
    case kind: NatPmpReqKind
    of nrDiscover:
      discard
    of nrMap:
      mapInternal: uint16
      mapExternal: uint16
      mapProto: MapProto
      mapLease: uint32
    of nrUnmap:
      unmapInternal: uint16
      unmapExternal: uint16
      unmapProto: MapProto
    of nrShutdown:
      discard

  NatPmpWorkerCtx = object
    reqSignal: ThreadSignalPtr
    respSignal: ThreadSignalPtr
    request: NatPmpRequest
    response: MapperResponse

  MappingKey = tuple[externalPort: uint16, proto: MapProto]

  NatPmpMapper* = ref object of PortMapper
    ctx: ptr NatPmpWorkerCtx
    thread: Thread[ptr NatPmpWorkerCtx]
    closed: Atomic[bool]
    lock: AsyncLock
    inflight: Future[void].Raising([AsyncError, CancelledError])
    drainPending: Future[void].Raising([AsyncError, CancelledError])
      ## Pending respSignal wait left over from a dispatch that timed out
      ## before the worker finished. The next dispatch awaits this first so
      ## it doesn't pick up the stale signal as its own response.
    mappings: Table[MappingKey, uint16]
      ## externalPort,proto -> internalPort, populated on successful map() so
      ## unmap() can send the correct internal port (NAT-PMP identifies a
      ## mapping by internal port + protocol, not by external port).

proc toPmpProto(p: MapProto): NatPmpProtocol =
  case p
  of mpTcp: NatPmpProtocol.TCP
  of mpUdp: NatPmpProtocol.UDP

proc ensureInit(pmp: var NatPmp, resp: var MapperResponse): bool =
  if pmp != nil:
    return true

  # Build the new NatPmp in a local first and only publish to `pmp` after a
  # successful init. If init fails, close() the local so any socket/state
  # libnatpmp may have opened gets released instead of being leaked when the
  # ref drops.
  let fresh = newNatPmp()
  let r = fresh.init()
  if r.isErr():
    resp.setError("natpmp init: " & $r.error())
    fresh.close()
    return false
  pmp = fresh
  true

proc handleDiscover(pmp: var NatPmp, resp: var MapperResponse) =
  if not ensureInit(pmp, resp):
    return

  let r = pmp.externalIPAddress()
  if r.isErr():
    resp.setError("natpmp externalIPAddress: " & $r.error())
    return

  try:
    resp.ip = Opt.some(parseIpAddress($r.get()))
    resp.success = true
  except ValueError as e:
    resp.setError("natpmp parseIpAddress: " & e.msg)

proc handleMap(pmp: var NatPmp, req: NatPmpRequest, resp: var MapperResponse) =
  if not ensureInit(pmp, resp):
    return

  let r = pmp.addPortMapping(
    eport = cushort(req.mapExternal),
    iport = cushort(req.mapInternal),
    protocol = toPmpProto(req.mapProto),
    lifetime = culong(req.mapLease),
  )
  if r.isErr():
    resp.setError("natpmp addPortMapping: " & $r.error())
    return

  resp.success = true
  resp.externalPort = uint16(r.get())

proc handleUnmap(pmp: var NatPmp, req: NatPmpRequest, resp: var MapperResponse) =
  if not ensureInit(pmp, resp):
    return

  let r = pmp.deletePortMapping(
    eport = cushort(req.unmapExternal),
    iport = cushort(req.unmapInternal),
    protocol = toPmpProto(req.unmapProto),
  )
  if r.isErr():
    resp.setError("natpmp deletePortMapping: " & $r.error())
    return

  resp.success = true

proc natpmpWorker(ctx: ptr NatPmpWorkerCtx) {.thread.} =
  var
    pmp: NatPmp = nil
    running = true

  while running:
    let w = ctx.reqSignal.waitSync()
    if w.isErr():
      break

    let req = ctx.request
    ctx.response = MapperResponse()

    case req.kind
    of nrDiscover:
      handleDiscover(pmp, ctx.response)
    of nrMap:
      handleMap(pmp, req, ctx.response)
    of nrUnmap:
      handleUnmap(pmp, req, ctx.response)
    of nrShutdown:
      running = false

    discard ctx.respSignal.fireSync()

  if pmp != nil:
    pmp.close()

proc drainPrevious(self: NatPmpMapper) {.async: (raises: []).} =
  ## Swallow a respSignal fire left over from a prior dispatch that timed
  ## out, so this dispatch's wait() doesn't short-circuit on it.
  if self.drainPending == nil:
    return
  let drain = self.drainPending
  self.drainPending = nil
  self.inflight = drain
  defer:
    self.inflight = nil
  try:
    await drain
  except AsyncError, CancelledError:
    discard

proc dispatch(
    self: NatPmpMapper, req: sink NatPmpRequest, timeout: Duration = InfiniteDuration
): Future[Result[MapperResponse, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  await self.lock.acquire()
  defer:
    try:
      self.lock.release()
    except AsyncLockError as e:
      raiseAssert "NatPmpMapper lock release failed: " & e.msg

  await self.drainPrevious()
  # Close can only have run at the awaits above; synchronous code below is
  # atomic, so one check here gates every subsequent self.ctx access.
  if self.closed.load():
    return err("NatPmpMapper closed")

  self.ctx.request = req
  let fireR = self.ctx.reqSignal.fireSyncOrErr()
  if fireR.isErr():
    return err("NatPmpMapper signal fire failed: " & fireR.error())

  let waitFut = self.ctx.respSignal.wait()
  self.inflight = waitFut
  defer:
    self.inflight = nil

  var timedOut = false
  try:
    # join() mirrors waitFut's completion but, if cancelled (here by
    # withTimeout's timer), does NOT cancel waitFut — leaving it armed for
    # the drainPending stash below.
    if await join(waitFut).withTimeout(timeout):
      await waitFut # surface AsyncError/CancelledError from the wait
    else:
      timedOut = true
  except AsyncError as e:
    return err("NatPmpMapper wait: " & e.msg)

  if timedOut:
    # Worker may fire respSignal late — let the next dispatch drain it.
    self.drainPending = waitFut
    return err("NatPmpMapper timeout")

  ok(self.ctx.response)

proc newNatPmpMapper*(): NatPmpMapper {.raises: [ResourceExhaustedError].} =
  let ctx = createShared(NatPmpWorkerCtx, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    free(ctx)
    raise newException(ResourceExhaustedError, "NatPmpMapper reqSignal: " & error)
  ctx.respSignal = ThreadSignalPtr.new().valueOr:
    free(ctx)
    raise newException(ResourceExhaustedError, "NatPmpMapper respSignal: " & error)

  let mapper = NatPmpMapper(ctx: ctx, lock: newAsyncLock())
  try:
    createThread(mapper.thread, natpmpWorker, ctx)
  except ValueError, ResourceExhaustedError:
    free(ctx)
    raise newException(ResourceExhaustedError, "NatPmpMapper thread create failed")
  mapper

method discover*(
    self: NatPmpMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let resp = ?await self.dispatch(NatPmpRequest(kind: nrDiscover), timeout)

  if not resp.success:
    return err(resp.getError())
  if resp.ip.isNone():
    return err("natpmp discover: missing IP in response")
  ok(resp.ip.get())

method map*(
    self: NatPmpMapper,
    internalPort: Port,
    externalPort: Port,
    proto: MapProto,
    lease: uint32,
): Future[Result[Port, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  # libnatpmp interprets lifetime == 0 as a delete (NAT-PMP RFC 6886 §3.4), so
  # silently passing it through would tear the mapping down instead of creating
  # one. Reject it explicitly.
  if lease == 0:
    return
      err("natpmp map: lease must be > 0 (lease=0 deletes the mapping per RFC 6886)")

  let resp = ?await self.dispatch(
    NatPmpRequest(
      kind: nrMap,
      mapInternal: internalPort.uint16,
      mapExternal: externalPort.uint16,
      mapProto: proto,
      mapLease: lease,
    )
  )

  if not resp.success:
    return err(resp.getError())

  self.mappings[(resp.externalPort, proto)] = internalPort.uint16
  ok(Port(resp.externalPort))

method unmap*(
    self: NatPmpMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  # NAT-PMP identifies a mapping by (internal port, protocol). The PortMapper
  # API only carries the external port through unmap(), so look up the
  # internal port we recorded when map() created the rule.
  let key: MappingKey = (externalPort.uint16, proto)
  if not self.mappings.hasKey(key):
    return
      err("natpmp unmap: no known mapping for external port " & $externalPort.uint16)
  let internalPort = self.mappings.getOrDefault(key)

  let resp = ?await self.dispatch(
    NatPmpRequest(
      kind: nrUnmap,
      unmapInternal: internalPort,
      unmapExternal: externalPort.uint16,
      unmapProto: proto,
    )
  )

  if not resp.success:
    return err(resp.getError())

  self.mappings.del(key)
  ok()

method close*(self: NatPmpMapper) {.async: (raises: []), gcsafe.} =
  # No cancellable awaits: the only await is `noCancel(lock.acquire())`, and
  # the lock release in the defer below is guarded against AsyncLockError —
  # which is a developer error (release without acquire), not a runtime
  # failure mode.
  if self.closed.exchange(true):
    return

  # Unblock any dispatch currently parked on respSignal so it can release the
  # lock — without this, noCancel(lock.acquire) below would block forever if
  # the worker is stuck inside libnatpmp. Also cancel any drain left over
  # from a previous timeout, since joinThread further down would otherwise
  # wait for the worker to fire respSignal first.
  let inflight = self.inflight
  if inflight != nil:
    inflight.cancelSoon()

  let drain = self.drainPending
  if drain != nil:
    drain.cancelSoon()

  # Wait uncancellably for any in-flight dispatch to release the lock so the
  # signal handles and ctx are not mutated/torn down while still in use.
  await noCancel(self.lock.acquire())
  defer:
    try:
      self.lock.release()
    except AsyncLockError as e:
      raiseAssert "NatPmpMapper lock release failed: " & e.msg

  self.ctx.request = NatPmpRequest(kind: nrShutdown)
  let fireR = self.ctx.reqSignal.fireSyncOrErr()
  if fireR.isErr():
    warn "NatPmpMapper shutdown signal failed", err = fireR.error()

  joinThread(self.thread)

  free(self.ctx)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## UPnP-IGD port mapper. The underlying `nat_traversal/miniupnpc` API is
## synchronous (blocking C calls into miniupnpc), so this module owns a
## dedicated worker thread that holds the `Miniupnp` instance for the lifetime
## of the mapper. An `AsyncLock` serializes concurrent main-thread callers, and
## all transferred data is fixed-size POD so no Nim GC heap crosses the thread
## boundary.

{.push raises: [].}

import std/[atomics, net]
import chronos, chronos/threadsync, chronicles, results
import nat_traversal/miniupnpc
import ./portmapper

logScope:
  topics = "libp2p natservice upnp"

type
  UpnpReqKind = enum
    urDiscover
    urMap
    urUnmap

  UpnpRequest = object
    case kind: UpnpReqKind
    of urDiscover:
      discoverDelayMs: cint
    of urMap:
      mapInternal: uint16
      mapExternal: uint16
      mapProto: MapProto
      mapLease: uint32
    of urUnmap:
      unmapExternal: uint16
      unmapProto: MapProto

  UpnpWorkerCtx = object
    reqSignal: ThreadSignalPtr
    respSignal: ThreadSignalPtr
    shutdown: Atomic[bool]
    request: UpnpRequest
    response: MapperResponse

  UpnpMapper* = ref object of PortMapper
    ctx: ptr UpnpWorkerCtx
    thread: Thread[ptr UpnpWorkerCtx]
    closed: Atomic[bool]
    # Serializes dispatch() callers so only one request is in flight at a time,
    # and orders close() after any in-flight dispatch.
    lock: AsyncLock

proc toUpnpProto(p: MapProto): UPNPProtocol =
  case p
  of mpTcp: UPNPProtocol.TCP
  of mpUdp: UPNPProtocol.UDP

proc handleDiscover(upnp: Miniupnp, req: UpnpRequest, resp: var MapperResponse) =
  upnp.discoverDelay = req.discoverDelayMs

  let dr = upnp.discover()
  if dr.isErr:
    resp.setError("upnp discover: " & $dr.error)
    return

  let igd = upnp.selectIGD()
  if igd != IGDFound:
    resp.setError("upnp selectIGD: " & $igd)
    return

  let ipr = upnp.externalIPAddress()
  if ipr.isErr:
    resp.setError("upnp externalIPAddress: " & $ipr.error)
    return

  try:
    resp.ip = Opt.some(parseIpAddress(ipr.get()))
    resp.success = true
  except ValueError as e:
    resp.setError("upnp parseIpAddress: " & e.msg)

proc handleMap(upnp: Miniupnp, req: UpnpRequest, resp: var MapperResponse) =
  # Clamp via uint64 so the int() conversion is safe on 32-bit targets where
  # high(int) < high(uint32).
  let lease = int(min(req.mapLease.uint64, uint64(high(int))))
  let r = upnp.addPortMapping(
    externalPort = $req.mapExternal,
    protocol = toUpnpProto(req.mapProto),
    internalHost = upnp.lanAddr,
    internalPort = $req.mapInternal,
    desc = "nim-libp2p",
    leaseDuration = lease,
  )
  if r.isErr:
    resp.setError("upnp addPortMapping: " & $r.error)
    return

  resp.externalPort = req.mapExternal # IGD:1 returns the requested port
  resp.success = true

proc handleUnmap(upnp: Miniupnp, req: UpnpRequest, resp: var MapperResponse) =
  let r = upnp.deletePortMapping(
    externalPort = $req.unmapExternal, protocol = toUpnpProto(req.unmapProto)
  )
  if r.isErr:
    resp.setError("upnp deletePortMapping: " & $r.error)
    return

  resp.success = true

proc upnpWorker(ctx: ptr UpnpWorkerCtx) {.thread.} =
  let upnp = newMiniupnp()
  defer:
    upnp.close()

  while true:
    let w = ctx.reqSignal.waitSync()
    if w.isErr:
      # Either reqSignal was closed (intentional shutdown unblock) or the
      # underlying primitive failed. Either way, the worker can't observe
      # further requests — exit. Closing respSignal unblocks any awaiter.
      error "UpnpMapper worker reqSignal wait failed", err = w.error
      discard ctx.respSignal.close()
      ctx.respSignal = nil # don't double-close in free()
      break
    if ctx.shutdown.load():
      error "UpnpMapper worker shutdown"
      break

    ctx.response = MapperResponse()

    case ctx.request.kind
    of urDiscover:
      handleDiscover(upnp, ctx.request, ctx.response)
    of urMap:
      handleMap(upnp, ctx.request, ctx.response)
    of urUnmap:
      handleUnmap(upnp, ctx.request, ctx.response)

    let fireR = ctx.respSignal.fireSyncOrErr()
    if fireR.isErr():
      # The awaiting dispatch() can't see this response. Close respSignal so
      # the wait errors out instead of hanging, then exit the worker.
      error "UpnpMapper worker respSignal fire failed", err = fireR.error()
      discard ctx.respSignal.close()
      ctx.respSignal = nil # don't double-close in free()
      break

proc dispatch(
    self: UpnpMapper, req: sink UpnpRequest
): Future[Result[MapperResponse, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if self.closed.load():
    return err("UpnpMapper closed")

  await self.lock.acquire()
  defer:
    self.lock.safeRelease("UpnpMapper")

  if self.closed.load():
    return err("UpnpMapper closed")

  self.ctx.request = req
  let fireR = self.ctx.reqSignal.fireSyncOrErr()
  if fireR.isErr():
    return err("UpnpMapper signal fire failed: " & fireR.error())

  try:
    await self.ctx.respSignal.wait()
  except AsyncError as e:
    return err("UpnpMapper wait: " & e.msg)
  except CancelledError as e:
    # The worker keeps running until it finishes the in-flight request and
    # fires respSignal. Drain that fire before releasing the lock, otherwise
    # the next dispatch would consume it and read this cancelled request's
    # response.
    try:
      await noCancel(self.ctx.respSignal.wait())
    except AsyncError:
      discard
    raise e

  if self.closed.load():
    return err("UpnpMapper closed")

  ok(self.ctx.response)

proc newUpnpMapper*(): UpnpMapper {.raises: [ResourceExhaustedError].} =
  let ctx = createShared(UpnpWorkerCtx, 1)
  initSignals(ctx, "UpnpMapper")

  let mapper = UpnpMapper(ctx: ctx, lock: newAsyncLock())

  try:
    createThread(mapper.thread, upnpWorker, ctx)
  except ValueError as e:
    free(ctx)
    raise
      newException(ResourceExhaustedError, "UpnpMapper thread create failed: " & e.msg)
  except ResourceExhaustedError as e:
    free(ctx)
    raise
      newException(ResourceExhaustedError, "UpnpMapper thread create failed: " & e.msg)

  mapper

method discover*(
    self: UpnpMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let delayMs = cint(timeout.milliseconds.clamp(0'i64, int64(high(cint))))
  let resp =
    ?await self.dispatch(UpnpRequest(kind: urDiscover, discoverDelayMs: delayMs))

  if not resp.success:
    return err(resp.getError())
  if resp.ip.isNone:
    return err("upnp discover: missing IP in response")
  ok(resp.ip.get())

method map*(
    self: UpnpMapper,
    internalPort: Port,
    externalPort: Port,
    proto: MapProto,
    lease: uint32,
): Future[Result[Port, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let resp = ?await self.dispatch(
    UpnpRequest(
      kind: urMap,
      mapInternal: uint16(internalPort),
      mapExternal: uint16(externalPort),
      mapProto: proto,
      mapLease: lease,
    )
  )

  if not resp.success:
    return err(resp.getError())
  ok(Port(resp.externalPort))

method unmap*(
    self: UpnpMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let resp = ?await self.dispatch(
    UpnpRequest(kind: urUnmap, unmapExternal: uint16(externalPort), unmapProto: proto)
  )

  if not resp.success:
    return err(resp.getError())
  ok()

method close*(self: UpnpMapper) {.async: (raises: []), gcsafe.} =
  # No cancellable awaits: the only await is `noCancel(lock.acquire())`, and
  # the lock release in the defer below is guarded against AsyncLockError —
  # which is a developer error (release without acquire), not a runtime
  # failure mode.
  if self.closed.exchange(true):
    return

  # Wait uncancellably for any in-flight dispatch to release the lock, so the
  # signal handles and ctx are not torn down while still in use.
  await noCancel(self.lock.acquire())
  defer:
    self.lock.safeRelease("UpnpMapper")

  # Tell the worker to exit. A separate shutdown flag (rather than a
  # urShutdown request) avoids racing with worker reads of ctx.request.
  self.ctx.shutdown.store(true)
  let fireR = self.ctx.reqSignal.fireSyncOrErr()
  if fireR.isErr():
    warn "UpnpMapper shutdown signal failed", err = fireR.error()
    # Force the worker's waitSync to return so it can exit and joinThread
    # below does not deadlock.
    discard self.ctx.reqSignal.close()
    self.ctx.reqSignal = nil # don't double-close in free()

  joinThread(self.thread)

  free(self.ctx)

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

const ErrBufLen = 256

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

  UpnpResponse = object
    success: bool
    errorLen: int
    errorBuf: array[ErrBufLen, char]
    ip: Opt[IpAddress]
    externalPort: uint16

  UpnpWorkerCtx = object
    reqSignal: ThreadSignalPtr
    respSignal: ThreadSignalPtr
    shutdown: Atomic[bool]
    request: UpnpRequest
    response: UpnpResponse

  UpnpMapper* = ref object of PortMapper
    ctx: ptr UpnpWorkerCtx
    thread: Thread[ptr UpnpWorkerCtx]
    closed: Atomic[bool]
    lock: AsyncLock

proc setError(resp: var UpnpResponse, msg: string) =
  resp.success = false
  resp.ip.reset()
  resp.externalPort = 0
  let n = min(msg.len, ErrBufLen)
  for i in 0 ..< n:
    resp.errorBuf[i] = msg[i]
  resp.errorLen = n

proc getError(resp: UpnpResponse): string =
  result = newString(resp.errorLen)
  for i in 0 ..< resp.errorLen:
    result[i] = resp.errorBuf[i]

proc toUpnpProto(p: MapProto): UPNPProtocol =
  case p
  of mpTcp: UPNPProtocol.TCP
  of mpUdp: UPNPProtocol.UDP

proc handleDiscover(upnp: Miniupnp, req: UpnpRequest, resp: var UpnpResponse) =
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

proc handleMap(upnp: Miniupnp, req: UpnpRequest, resp: var UpnpResponse) =
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

proc handleUnmap(upnp: Miniupnp, req: UpnpRequest, resp: var UpnpResponse) =
  let r = upnp.deletePortMapping(
    externalPort = $req.unmapExternal, protocol = toUpnpProto(req.unmapProto)
  )
  if r.isErr:
    resp.setError("upnp deletePortMapping: " & $r.error)
    return

  resp.success = true

proc upnpWorker(ctx: ptr UpnpWorkerCtx) {.thread.} =
  let upnp = newMiniupnp()

  while true:
    let w = ctx.reqSignal.waitSync()
    if w.isErr or ctx.shutdown.load:
      break

    ctx.response = UpnpResponse()

    case ctx.request.kind
    of urDiscover:
      handleDiscover(upnp, ctx.request, ctx.response)
    of urMap:
      handleMap(upnp, ctx.request, ctx.response)
    of urUnmap:
      handleUnmap(upnp, ctx.request, ctx.response)

    discard ctx.respSignal.fireSync()

  upnp.close()

proc dispatch(
    self: UpnpMapper, req: sink UpnpRequest
): Future[Result[UpnpResponse, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  if self.closed.load:
    return err("UpnpMapper closed")

  await self.lock.acquire()
  try:
    if self.closed.load:
      return err("UpnpMapper closed")

    self.ctx.request = req
    let fr = self.ctx.reqSignal.fireSync()
    if fr.isErr or not fr.get():
      return err("UpnpMapper signal fire failed")

    try:
      await self.ctx.respSignal.wait()
    except AsyncError as e:
      return err("UpnpMapper wait: " & e.msg)
    except CancelledError as exc:
      # The worker keeps running until it finishes the in-flight request and
      # fires respSignal. Drain that fire before releasing the lock, otherwise
      # the next dispatch would consume it and read this cancelled request's
      # response.
      try:
        await noCancel(self.ctx.respSignal.wait())
      except AsyncError:
        discard
      raise exc

    if self.closed.load:
      return err("UpnpMapper closed")

    return ok(self.ctx.response)
  finally:
    try:
      self.lock.release()
    except AsyncLockError as e:
      warn "UpnpMapper lock release failed", err = e.msg

proc newUpnpMapper*(): UpnpMapper {.raises: [ResourceExhaustedError].} =
  let ctx = createShared(UpnpWorkerCtx, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "UpnpMapper reqSignal: " & error)
  ctx.respSignal = ThreadSignalPtr.new().valueOr:
    discard ctx.reqSignal.close()
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "UpnpMapper respSignal: " & error)

  result = UpnpMapper(ctx: ctx, lock: newAsyncLock())

  try:
    createThread(result.thread, upnpWorker, ctx)
  except ValueError, ResourceExhaustedError:
    discard ctx.reqSignal.close()
    discard ctx.respSignal.close()
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "UpnpMapper thread create failed")

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

method close*(self: UpnpMapper) {.async: (raises: [CancelledError]), gcsafe.} =
  if self.closed.exchange(true):
    return

  # Wait uncancellably for any in-flight dispatch to release the lock, so the
  # signal handles and ctx are not torn down while still in use.
  await noCancel(self.lock.acquire())
  try:
    # Tell the worker to exit. A separate shutdown flag (rather than a
    # urShutdown request) avoids racing with worker reads of ctx.request.
    self.ctx.shutdown.store(true)
    let fr = self.ctx.reqSignal.fireSync()
    if fr.isErr or not fr.get():
      warn "UpnpMapper shutdown signal failed",
        err = (if fr.isErr: fr.error else: "timeout")

    try:
      joinThread(self.thread)
    except CatchableError as e:
      warn "UpnpMapper joinThread failed", err = e.msg

    discard self.ctx.reqSignal.close()
    discard self.ctx.respSignal.close()
    freeShared(self.ctx)
  finally:
    try:
      self.lock.release()
    except AsyncLockError as e:
      warn "UpnpMapper lock release failed", err = e.msg

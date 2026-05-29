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

const
  ErrBufLen = 256
  IpBufLen = 16

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

  NatPmpResponse = object
    success: bool
    errorLen: int
    errorBuf: array[ErrBufLen, char]
    ipFamily: int
    ipBuf: array[IpBufLen, byte]
    externalPort: uint16

  NatPmpWorkerCtx = object
    reqSignal: ThreadSignalPtr
    respSignal: ThreadSignalPtr
    request: NatPmpRequest
    response: NatPmpResponse

  MappingKey = tuple[externalPort: uint16, proto: MapProto]

  NatPmpMapper* = ref object of PortMapper
    ctx: ptr NatPmpWorkerCtx
    thread: Thread[ptr NatPmpWorkerCtx]
    closed: Atomic[bool]
    lock: AsyncLock
    inflight: Future[void]
    drainPending: Future[void]
      ## Pending respSignal wait left over from a dispatch that timed out
      ## before the worker finished. The next dispatch awaits this first so
      ## it doesn't pick up the stale signal as its own response.
    mappings: Table[MappingKey, uint16]
      ## externalPort,proto -> internalPort, populated on successful map() so
      ## unmap() can send the correct internal port (NAT-PMP identifies a
      ## mapping by internal port + protocol, not by external port).

proc setError(resp: var NatPmpResponse, msg: string) =
  resp.success = false
  resp.ipFamily = 0
  resp.externalPort = 0
  let n = min(msg.len, ErrBufLen)
  for i in 0 ..< n:
    resp.errorBuf[i] = msg[i]
  resp.errorLen = n

proc getError(resp: NatPmpResponse): string =
  var msg = newString(resp.errorLen)
  for i in 0 ..< resp.errorLen:
    msg[i] = resp.errorBuf[i]
  msg

proc setIp(resp: var NatPmpResponse, ip: IpAddress) =
  case ip.family
  of IpAddressFamily.IPv4:
    resp.ipFamily = 4
    for i in 0 .. 3:
      resp.ipBuf[i] = ip.address_v4[i]
  of IpAddressFamily.IPv6:
    resp.ipFamily = 6
    for i in 0 .. 15:
      resp.ipBuf[i] = ip.address_v6[i]

proc getIp(resp: NatPmpResponse): Opt[IpAddress] =
  case resp.ipFamily
  of 4:
    var ip = IpAddress(family: IpAddressFamily.IPv4)
    for i in 0 .. 3:
      ip.address_v4[i] = resp.ipBuf[i]
    Opt.some(ip)
  of 6:
    var ip = IpAddress(family: IpAddressFamily.IPv6)
    for i in 0 .. 15:
      ip.address_v6[i] = resp.ipBuf[i]
    Opt.some(ip)
  else:
    Opt.none(IpAddress)

proc toPmpProto(p: MapProto): NatPmpProtocol =
  case p
  of mpTcp: NatPmpProtocol.TCP
  of mpUdp: NatPmpProtocol.UDP

proc ensureInit(pmp: var NatPmp, resp: var NatPmpResponse): bool =
  if pmp != nil:
    return true

  pmp = newNatPmp()
  let r = pmp.init()
  if r.isErr:
    resp.setError("natpmp init: " & $r.error)
    pmp = nil
    return false
  true

proc handleDiscover(pmp: var NatPmp, resp: var NatPmpResponse) =
  if not ensureInit(pmp, resp):
    return

  let r = pmp.externalIPAddress()
  if r.isErr:
    resp.setError("natpmp externalIPAddress: " & $r.error)
    return

  try:
    let ip = parseIpAddress($r.get())
    resp.success = true
    resp.setIp(ip)
  except ValueError as exc:
    resp.setError("natpmp parseIpAddress: " & exc.msg)

proc handleMap(pmp: var NatPmp, req: NatPmpRequest, resp: var NatPmpResponse) =
  if not ensureInit(pmp, resp):
    return

  let r = pmp.addPortMapping(
    eport = cushort(req.mapExternal),
    iport = cushort(req.mapInternal),
    protocol = toPmpProto(req.mapProto),
    lifetime = culong(req.mapLease),
  )
  if r.isErr:
    resp.setError("natpmp addPortMapping: " & $r.error)
    return

  resp.success = true
  resp.externalPort = uint16(r.get())

proc handleUnmap(pmp: var NatPmp, req: NatPmpRequest, resp: var NatPmpResponse) =
  if not ensureInit(pmp, resp):
    return

  let r = pmp.deletePortMapping(
    eport = cushort(req.unmapExternal),
    iport = cushort(req.unmapInternal),
    protocol = toPmpProto(req.unmapProto),
  )
  if r.isErr:
    resp.setError("natpmp deletePortMapping: " & $r.error)
    return

  resp.success = true

proc natpmpWorker(ctx: ptr NatPmpWorkerCtx) {.thread.} =
  var pmp: NatPmp = nil

  while true:
    let w = ctx.reqSignal.waitSync()
    if w.isErr:
      break

    let req = ctx.request
    ctx.response = NatPmpResponse()

    case req.kind
    of nrDiscover:
      handleDiscover(pmp, ctx.response)
    of nrMap:
      handleMap(pmp, req, ctx.response)
    of nrUnmap:
      handleUnmap(pmp, req, ctx.response)
    of nrShutdown:
      if pmp != nil:
        pmp.close()
        pmp = nil
      discard ctx.respSignal.fireSync()
      break

    discard ctx.respSignal.fireSync()

proc dispatch(
    self: NatPmpMapper, req: sink NatPmpRequest, timeout: Duration = InfiniteDuration
): Future[NatPmpResponse] {.async: (raises: [CancelledError]).} =
  if self.closed.load:
    raise newException(CancelledError, "NatPmpMapper closed")

  await self.lock.acquire()
  try:
    if self.closed.load:
      raise newException(CancelledError, "NatPmpMapper closed")

    # A previous dispatch may have timed out before the worker fired
    # respSignal. Consume that lingering signal here so the caller's timeout
    # below only governs its own request — not the previous one's tail.
    if self.drainPending != nil:
      let drain = self.drainPending
      self.drainPending = nil
      self.inflight = drain
      try:
        await drain
      except AsyncError, CancelledError:
        discard
      self.inflight = nil
      if self.closed.load:
        raise newException(CancelledError, "NatPmpMapper closed")

    self.ctx.request = req
    let fr = self.ctx.reqSignal.fireSync()
    if fr.isErr or not fr.get():
      raise newException(CancelledError, "NatPmpMapper signal fire failed")

    let waitFut = self.ctx.respSignal.wait()
    self.inflight = waitFut
    var timedOut = false
    try:
      try:
        if timeout == InfiniteDuration:
          await waitFut
        elif not await waitFut.withTimeout(timeout):
          timedOut = true
      except AsyncError as exc:
        raise newException(CancelledError, "NatPmpMapper wait: " & exc.msg)
    finally:
      self.inflight = nil

    if timedOut:
      # waitFut is still pending; the worker will fire respSignal once
      # libnatpmp's internal retry loop gives up. Stash the wait so the
      # NEXT dispatch drains it, instead of blocking this caller past its
      # requested timeout.
      self.drainPending = waitFut
      raise newException(CancelledError, "NatPmpMapper timeout")

    # Copy the response out under the lock so callers don't race with the
    # next dispatch overwriting self.ctx.response.
    return self.ctx.response
  finally:
    try:
      self.lock.release()
    except AsyncLockError:
      discard

proc new*(T: typedesc[NatPmpMapper]): T {.raises: [ResourceExhaustedError].} =
  let ctx = createShared(NatPmpWorkerCtx, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "NatPmpMapper reqSignal: " & error)
  ctx.respSignal = ThreadSignalPtr.new().valueOr:
    discard ctx.reqSignal.close()
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "NatPmpMapper respSignal: " & error)

  let mapper = NatPmpMapper(ctx: ctx, lock: newAsyncLock())

  try:
    createThread(mapper.thread, natpmpWorker, ctx)
  except ValueError, ResourceExhaustedError:
    discard ctx.reqSignal.close()
    discard ctx.respSignal.close()
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "NatPmpMapper thread create failed")

  mapper

method discover*(
    self: NatPmpMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  let resp = await self.dispatch(NatPmpRequest(kind: nrDiscover), timeout)

  if not resp.success:
    return Result[IpAddress, string].err(resp.getError())
  let ipOpt = resp.getIp()
  if ipOpt.isNone:
    return Result[IpAddress, string].err("natpmp discover: missing IP in response")
  Result[IpAddress, string].ok(ipOpt.get())

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
    return Result[Port, string].err(
      "natpmp map: lease must be > 0 (lease=0 deletes the mapping per RFC 6886)"
    )

  let resp = await self.dispatch(
    NatPmpRequest(
      kind: nrMap,
      mapInternal: uint16(internalPort),
      mapExternal: uint16(externalPort),
      mapProto: proto,
      mapLease: lease,
    )
  )

  if resp.success:
    let mapped = Port(resp.externalPort)
    self.mappings[(uint16(mapped), proto)] = uint16(internalPort)
    return Result[Port, string].ok(mapped)
  Result[Port, string].err(resp.getError())

method unmap*(
    self: NatPmpMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  # NAT-PMP identifies a mapping by (internal port, protocol). The PortMapper
  # API only carries the external port through unmap(), so look up the
  # internal port we recorded when map() created the rule.
  let key: MappingKey = (uint16(externalPort), proto)
  if not self.mappings.hasKey(key):
    return Result[void, string].err(
      "natpmp unmap: no known mapping for external port " & $uint16(externalPort)
    )
  let internalPort = self.mappings.getOrDefault(key)

  let resp = await self.dispatch(
    NatPmpRequest(
      kind: nrUnmap,
      unmapInternal: internalPort,
      unmapExternal: uint16(externalPort),
      unmapProto: proto,
    )
  )

  if resp.success:
    self.mappings.del(key)
    return Result[void, string].ok()
  Result[void, string].err(resp.getError())

method close*(self: NatPmpMapper) {.gcsafe, raises: [].} =
  if self.closed.exchange(true):
    return

  # Unblock any dispatch currently parked on respSignal so the caller sees
  # CancelledError instead of waiting for a response that may never come if
  # the worker is stuck inside libnatpmp. Also cancel any drain left over
  # from a previous timeout, since joinThread below would otherwise wait
  # for the worker to fire respSignal first.
  let inflight = self.inflight
  if inflight != nil and not inflight.finished():
    inflight.cancelSoon()

  let drain = self.drainPending
  if drain != nil and not drain.finished():
    drain.cancelSoon()

  self.ctx.request = NatPmpRequest(kind: nrShutdown)
  let fr = self.ctx.reqSignal.fireSync()
  if fr.isErr or not fr.get():
    warn "NatPmpMapper shutdown signal failed",
      err = (if fr.isErr: fr.error else: "timeout")

  try:
    joinThread(self.thread)
  except Exception as exc:
    warn "NatPmpMapper joinThread failed", err = exc.msg

  discard self.ctx.reqSignal.close()
  discard self.ctx.respSignal.close()
  freeShared(self.ctx)

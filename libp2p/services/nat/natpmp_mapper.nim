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
  result = newString(resp.errorLen)
  for i in 0 ..< resp.errorLen:
    result[i] = resp.errorBuf[i]

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
): Future[void] {.async: (raises: [CancelledError]).} =
  if self.closed.load:
    raise newException(CancelledError, "NatPmpMapper closed")

  await self.lock.acquire()
  try:
    if self.closed.load:
      raise newException(CancelledError, "NatPmpMapper closed")

    self.ctx.request = req
    let fr = self.ctx.reqSignal.fireSync()
    if fr.isErr or not fr.get():
      raise newException(CancelledError, "NatPmpMapper signal fire failed")

    let waitFut = self.ctx.respSignal.wait()
    self.inflight = waitFut
    try:
      try:
        if timeout == InfiniteDuration:
          await waitFut
        else:
          if not await waitFut.withTimeout(timeout):
            # Timed out; the worker is still running its blocking call (libnatpmp
            # has its own internal retry timeout). Drain respSignal before
            # releasing the lock so the next dispatch starts with clean state.
            let drainFut = self.ctx.respSignal.wait()
            self.inflight = drainFut
            try:
              await drainFut
            except AsyncError, CancelledError:
              discard
            raise newException(CancelledError, "NatPmpMapper timeout")
      except AsyncError as exc:
        raise newException(CancelledError, "NatPmpMapper wait: " & exc.msg)
    finally:
      self.inflight = nil
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

  result = NatPmpMapper(ctx: ctx, lock: newAsyncLock())

  try:
    createThread(result.thread, natpmpWorker, ctx)
  except ValueError, ResourceExhaustedError:
    discard ctx.reqSignal.close()
    discard ctx.respSignal.close()
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "NatPmpMapper thread create failed")

method discover*(
    self: NatPmpMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  await self.dispatch(NatPmpRequest(kind: nrDiscover), timeout)

  if not self.ctx.response.success:
    return Result[IpAddress, string].err(self.ctx.response.getError())
  let ipOpt = self.ctx.response.getIp()
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

  await self.dispatch(
    NatPmpRequest(
      kind: nrMap,
      mapInternal: uint16(internalPort),
      mapExternal: uint16(externalPort),
      mapProto: proto,
      mapLease: lease,
    )
  )

  if self.ctx.response.success:
    let mapped = Port(self.ctx.response.externalPort)
    self.mappings[(uint16(mapped), proto)] = uint16(internalPort)
    return Result[Port, string].ok(mapped)
  Result[Port, string].err(self.ctx.response.getError())

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

  await self.dispatch(
    NatPmpRequest(
      kind: nrUnmap,
      unmapInternal: internalPort,
      unmapExternal: uint16(externalPort),
      unmapProto: proto,
    )
  )

  if self.ctx.response.success:
    self.mappings.del(key)
    return Result[void, string].ok()
  Result[void, string].err(self.ctx.response.getError())

method close*(self: NatPmpMapper) {.gcsafe, raises: [].} =
  if self.closed.exchange(true):
    return

  # Unblock any dispatch currently parked on respSignal so the caller sees
  # CancelledError instead of waiting for a response that may never come if
  # the worker is stuck inside libnatpmp.
  let inflight = self.inflight
  if inflight != nil and not inflight.finished():
    inflight.cancelSoon()

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

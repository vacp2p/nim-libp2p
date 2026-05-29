# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## NAT-PMP port mapper. Mirrors the worker-thread structure of upnp_mapper.nim
## around the `nat_traversal/natpmp` sync bindings.

{.push raises: [].}

import std/[atomics, net]
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

  NatPmpMapper* = ref object of PortMapper
    ctx: ptr NatPmpWorkerCtx
    thread: Thread[ptr NatPmpWorkerCtx]
    closed: Atomic[bool]

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
    iport = cushort(req.unmapExternal),
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

    ctx.response = NatPmpResponse()

    case ctx.request.kind
    of nrDiscover:
      handleDiscover(pmp, ctx.response)
    of nrMap:
      handleMap(pmp, ctx.request, ctx.response)
    of nrUnmap:
      handleUnmap(pmp, ctx.request, ctx.response)
    of nrShutdown:
      if pmp != nil:
        pmp.close()
        pmp = nil
      discard ctx.respSignal.fireSync()
      break

    discard ctx.respSignal.fireSync()

proc dispatch(
    self: NatPmpMapper, req: sink NatPmpRequest
): Future[void] {.async: (raises: [CancelledError]).} =
  if self.closed.load:
    raise newException(CancelledError, "NatPmpMapper closed")

  self.ctx.request = req
  let fr = self.ctx.reqSignal.fireSync()
  if fr.isErr or not fr.get():
    raise newException(CancelledError, "NatPmpMapper signal fire failed")

  try:
    await self.ctx.respSignal.wait()
  except AsyncError as exc:
    raise newException(CancelledError, "NatPmpMapper wait: " & exc.msg)

proc new*(T: typedesc[NatPmpMapper]): T {.raises: [ResourceExhaustedError].} =
  let ctx = createShared(NatPmpWorkerCtx, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "NatPmpMapper reqSignal: " & error)
  ctx.respSignal = ThreadSignalPtr.new().valueOr:
    discard ctx.reqSignal.close()
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "NatPmpMapper respSignal: " & error)

  result = T(ctx: ctx)

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
  await self.dispatch(NatPmpRequest(kind: nrDiscover))

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
    return Result[Port, string].ok(Port(self.ctx.response.externalPort))
  Result[Port, string].err(self.ctx.response.getError())

method unmap*(
    self: NatPmpMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  await self.dispatch(
    NatPmpRequest(kind: nrUnmap, unmapExternal: uint16(externalPort), unmapProto: proto)
  )

  if self.ctx.response.success:
    return Result[void, string].ok()
  Result[void, string].err(self.ctx.response.getError())

method close*(self: NatPmpMapper) {.gcsafe, raises: [].} =
  if self.closed.exchange(true):
    return

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

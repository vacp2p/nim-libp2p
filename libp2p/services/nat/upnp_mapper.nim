# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

## UPnP-IGD port mapper. The underlying `nat_traversal/miniupnpc` API is
## synchronous (blocking C calls into miniupnpc), so this module owns a
## dedicated worker thread that holds the `Miniupnp` instance for the lifetime
## of the mapper. The async API on top dispatches one request at a time to the
## worker via two `ThreadSignalPtr`s, with all transferred data laid out as
## fixed-size POD so no Nim GC heap crosses the thread boundary.

{.push raises: [].}

import std/[atomics, net]
import chronos, chronos/threadsync, chronicles, results
import nat_traversal/miniupnpc
import ./portmapper

logScope:
  topics = "libp2p natservice upnp"

const
  ErrBufLen = 256
  IpBufLen = 16

type
  UpnpReqKind = enum
    urDiscover
    urMap
    urUnmap
    urShutdown

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
    of urShutdown:
      discard

  UpnpResponse = object
    success: bool
    errorLen: int
    errorBuf: array[ErrBufLen, char]
    ipFamily: int # 0 = unset, 4 = IPv4, 6 = IPv6
    ipBuf: array[IpBufLen, byte]
    externalPort: uint16

  UpnpWorkerCtx = object
    reqSignal: ThreadSignalPtr
    respSignal: ThreadSignalPtr
    request: UpnpRequest
    response: UpnpResponse

  UpnpMapper* = ref object of PortMapper
    ctx: ptr UpnpWorkerCtx
    thread: Thread[ptr UpnpWorkerCtx]
    closed: Atomic[bool]

# ----------------------------------------------------------------------------
# Response buffer helpers (called from both threads; only touch POD fields)
# ----------------------------------------------------------------------------

proc setError(resp: var UpnpResponse, msg: string) =
  resp.success = false
  resp.ipFamily = 0
  resp.externalPort = 0
  let n = min(msg.len, ErrBufLen)
  for i in 0 ..< n:
    resp.errorBuf[i] = msg[i]
  resp.errorLen = n

proc getError(resp: UpnpResponse): string =
  var msg = newString(resp.errorLen)
  for i in 0 ..< resp.errorLen:
    msg[i] = resp.errorBuf[i]
  msg

proc setIp(resp: var UpnpResponse, ip: IpAddress) =
  case ip.family
  of IpAddressFamily.IPv4:
    resp.ipFamily = 4
    for i in 0 .. 3:
      resp.ipBuf[i] = ip.address_v4[i]
  of IpAddressFamily.IPv6:
    resp.ipFamily = 6
    for i in 0 .. 15:
      resp.ipBuf[i] = ip.address_v6[i]

proc getIp(resp: UpnpResponse): Opt[IpAddress] =
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

# ----------------------------------------------------------------------------
# Worker thread body
# ----------------------------------------------------------------------------

proc toUpnpProto(p: MapProto): UPNPProtocol =
  case p
  of mpTcp: UPNPProtocol.TCP
  of mpUdp: UPNPProtocol.UDP

proc handleDiscover(upnp: var Miniupnp, req: UpnpRequest, resp: var UpnpResponse) =
  if upnp == nil:
    upnp = newMiniupnp()
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
    let ip = parseIpAddress(ipr.get())
    resp.success = true
    resp.setIp(ip)
  except ValueError as exc:
    resp.setError("upnp parseIpAddress: " & exc.msg)

proc handleMap(upnp: Miniupnp, req: UpnpRequest, resp: var UpnpResponse) =
  if upnp == nil:
    resp.setError("upnp map: not discovered")
    return

  let r = upnp.addPortMapping(
    externalPort = $req.mapExternal,
    protocol = toUpnpProto(req.mapProto),
    internalHost = upnp.lanAddr,
    internalPort = $req.mapInternal,
    desc = "nim-libp2p",
    leaseDuration = int(req.mapLease),
  )
  if r.isErr:
    resp.setError("upnp addPortMapping: " & $r.error)
    return

  resp.success = true
  resp.externalPort = req.mapExternal # IGD:1 returns the requested port

proc handleUnmap(upnp: Miniupnp, req: UpnpRequest, resp: var UpnpResponse) =
  if upnp == nil:
    resp.setError("upnp unmap: not discovered")
    return

  let r = upnp.deletePortMapping(
    externalPort = $req.unmapExternal, protocol = toUpnpProto(req.unmapProto)
  )
  if r.isErr:
    resp.setError("upnp deletePortMapping: " & $r.error)
    return

  resp.success = true

proc upnpWorker(ctx: ptr UpnpWorkerCtx) {.thread.} =
  var upnp: Miniupnp = nil

  while true:
    let w = ctx.reqSignal.waitSync()
    if w.isErr:
      # signal closed or fatal — bail out
      break

    ctx.response = UpnpResponse()

    case ctx.request.kind
    of urDiscover:
      handleDiscover(upnp, ctx.request, ctx.response)
    of urMap:
      handleMap(upnp, ctx.request, ctx.response)
    of urUnmap:
      handleUnmap(upnp, ctx.request, ctx.response)
    of urShutdown:
      if upnp != nil:
        upnp.close()
        upnp = nil
      discard ctx.respSignal.fireSync()
      break

    discard ctx.respSignal.fireSync()

# ----------------------------------------------------------------------------
# Main-thread async dispatch
# ----------------------------------------------------------------------------

proc dispatch(
    self: UpnpMapper, req: sink UpnpRequest
): Future[void] {.async: (raises: [CancelledError]).} =
  if self.closed.load:
    raise newException(CancelledError, "UpnpMapper closed")

  self.ctx.request = req
  let fr = self.ctx.reqSignal.fireSync()
  if fr.isErr or not fr.get():
    raise newException(CancelledError, "UpnpMapper signal fire failed")

  try:
    await self.ctx.respSignal.wait()
  except AsyncError as exc:
    raise newException(CancelledError, "UpnpMapper wait: " & exc.msg)

proc new*(T: typedesc[UpnpMapper]): T {.raises: [ResourceExhaustedError].} =
  let ctx = createShared(UpnpWorkerCtx, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "UpnpMapper reqSignal: " & error)
  ctx.respSignal = ThreadSignalPtr.new().valueOr:
    discard ctx.reqSignal.close()
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "UpnpMapper respSignal: " & error)

  let mapper = T(ctx: ctx)

  try:
    createThread(mapper.thread, upnpWorker, ctx)
  except ValueError, ResourceExhaustedError:
    discard ctx.reqSignal.close()
    discard ctx.respSignal.close()
    freeShared(ctx)
    raise newException(ResourceExhaustedError, "UpnpMapper thread create failed")

  mapper

method discover*(
    self: UpnpMapper, timeout: Duration
): Future[Result[IpAddress, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  await self.dispatch(
    UpnpRequest(kind: urDiscover, discoverDelayMs: cint(timeout.milliseconds))
  )

  if not self.ctx.response.success:
    return Result[IpAddress, string].err(self.ctx.response.getError())
  let ipOpt = self.ctx.response.getIp()
  if ipOpt.isNone:
    return Result[IpAddress, string].err("upnp discover: missing IP in response")
  Result[IpAddress, string].ok(ipOpt.get())

method map*(
    self: UpnpMapper,
    internalPort: Port,
    externalPort: Port,
    proto: MapProto,
    lease: uint32,
): Future[Result[Port, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  await self.dispatch(
    UpnpRequest(
      kind: urMap,
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
    self: UpnpMapper, externalPort: Port, proto: MapProto
): Future[Result[void, string]] {.async: (raises: [CancelledError]), gcsafe.} =
  await self.dispatch(
    UpnpRequest(kind: urUnmap, unmapExternal: uint16(externalPort), unmapProto: proto)
  )

  if self.ctx.response.success:
    return Result[void, string].ok()
  Result[void, string].err(self.ctx.response.getError())

method close*(self: UpnpMapper) {.gcsafe, raises: [].} =
  if self.closed.exchange(true):
    return

  self.ctx.request = UpnpRequest(kind: urShutdown)
  let fr = self.ctx.reqSignal.fireSync()
  if fr.isErr or not fr.get():
    warn "UpnpMapper shutdown signal failed",
      err = (if fr.isErr: fr.error else: "timeout")

  try:
    joinThread(self.thread)
  except Exception as exc:
    warn "UpnpMapper joinThread failed", err = exc.msg

  discard self.ctx.reqSignal.close()
  discard self.ctx.respSignal.close()
  freeShared(self.ctx)

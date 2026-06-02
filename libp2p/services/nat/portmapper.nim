# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.push raises: [].}

import std/[net]
import chronos, chronos/threadsync, results

const ErrBufLen* = 256

type
  MapProto* = enum
    mpTcp
    mpUdp

  MapperResponse* = object
    ## POD payload returned by a worker thread to the dispatch caller. All
    ## fields are fixed-size value types so the response is safe to copy across
    ## the thread boundary without crossing the Nim GC heap.
    success*: bool
    errorLen*: int
    errorBuf*: array[ErrBufLen, char]
    ip*: Opt[IpAddress]
    externalPort*: uint16

  PortMapper* = ref object of RootObj
    ## Abstract base for a NAT port-mapping client (UPnP / NAT-PMP / mock).
    ## All operations are async because real implementations dispatch the
    ## underlying sync C calls to a dedicated worker thread.

proc setError*(resp: var MapperResponse, msg: string) =
  resp.success = false
  resp.ip.reset()
  resp.externalPort = 0
  let n = min(msg.len(), ErrBufLen)
  for i in 0 ..< n:
    resp.errorBuf[i] = msg[i]
  resp.errorLen = n

proc getError*(resp: MapperResponse): string =
  var s = newString(resp.errorLen)
  for i in 0 ..< resp.errorLen:
    s[i] = resp.errorBuf[i]
  s

proc free*[T](ctx: ptr T) =
  ## Releases a worker ctx's `reqSignal`/`respSignal` and the shared allocation.
  ## Tolerates partial initialization — a signal field that was never assigned
  ## (or that was already closed in-place) is left as nil and skipped here.
  if not ctx.reqSignal.isNil:
    discard ctx.reqSignal.close()
  if not ctx.respSignal.isNil:
    discard ctx.respSignal.close()
  freeShared(ctx)

proc fireSyncOrErr*(signal: ThreadSignalPtr): Result[void, string] =
  ## Wraps `fireSync` so both failure modes (underlying error or completion
  ## within the internal timeout returning false) surface as a single Result —
  ## callers branch once instead of unfolding `isErr`/`not get()` twice.
  let fr = signal.fireSync()
  if fr.isErr():
    return err(fr.error())
  if not fr.get():
    return err("fireSync timed out")
  ok()

proc safeRelease*(lock: AsyncLock, owner: static string) =
  ## Releases an AsyncLock from a defer block. `AsyncLockError` (release without
  ## acquire) is a developer error, not a runtime mode — surface it as an
  ## assertion so the bug is caught loud instead of silently warned.
  try:
    lock.release()
  except AsyncLockError as e:
    raiseAssert owner & " lock release failed: " & e.msg

proc initSignals*[T](
    ctx: ptr T, owner: static string
) {.raises: [ResourceExhaustedError].} =
  ## Allocates `reqSignal` + `respSignal` on the worker ctx; on either failure
  ## frees what was already allocated (via `free`) and raises with `owner` as
  ## the message prefix so the caller knows which mapper hit the limit.
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    free(ctx)
    raise newException(ResourceExhaustedError, owner & " reqSignal: " & error)
  ctx.respSignal = ThreadSignalPtr.new().valueOr:
    free(ctx)
    raise newException(ResourceExhaustedError, owner & " respSignal: " & error)

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

method close*(self: PortMapper) {.base, async: (raises: []), gcsafe.} =
  discard

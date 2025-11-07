# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

when defined(linux):
  {.passl: "-Wl,-soname,libp2p.so".}

import std/[typetraits, tables, atomics], chronos, chronicles
import
  ./libp2p_thread/libp2p_thread,
  ./[ffi_types, types],
  ./libp2p_thread/inter_thread_communication/libp2p_thread_request,
  ./libp2p_thread/inter_thread_communication/requests/
    [libp2p_lifecycle_requests, libp2p_hello_requests],
  ../libp2p
################################################################################
### Not-exported components
################################################################################

template checkLibParams*(
    ctx: ptr LibP2PContext, callback: Libp2pCallback, userData: pointer
) =
  ## This template checks common parameters passed to exported functions
  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK.cint

template callEventCallback(ctx: ptr LibP2PContext, eventName: string, body: untyped) =
  ## This template invokes the event callback for internal events
  if isNil(ctx[].eventCallback):
    error eventName & " - eventCallback is nil"
    return

  if isNil(ctx[].eventUserData):
    error eventName & " - eventUserData is nil"
    return

  foreignThreadGc:
    try:
      let event = body
      cast[Libp2pCallback](ctx[].eventCallback)(
        RET_OK, addr event[0], cast[csize_t](len(event)), ctx[].eventUserData
      )
    except Exception, CatchableError:
      let msg =
        "Exception " & eventName & " when calling 'eventCallBack': " &
        getCurrentExceptionMsg()
      cast[Libp2pCallback](ctx[].eventCallback)(
        RET_ERR, addr msg[0], cast[csize_t](len(msg)), ctx[].eventUserData
      )

# Sends a request to the worker thread and returns success/failure
proc handleRequest(
    ctx: ptr LibP2PContext,
    requestType: RequestType,
    content: pointer,
    callback: Libp2pCallback,
    userData: pointer,
): RetCode =
  libp2p_thread.sendRequestToLibP2PThread(ctx, requestType, content, callback, userData).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, addr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR

  return RET_OK

### End of not-exported components
################################################################################

################################################################################
### Library setup

# Required for Nim runtime initialization when using --nimMainPrefix
proc libp2pNimMain() {.importc.}

# Atomic flag to prevent multiple initializations
var initialized: Atomic[bool]

if defined(android):
  # Redirect chronicles to Android System logs
  when compiles(defaultChroniclesStream.outputs[0].writer):
    defaultChroniclesStream.outputs[0].writer = proc(
        logLevel: LogLevel, msg: LogOutputStr
    ) {.raises: [].} =
      echo logLevel, msg

# Initializes the Nim runtime and foreign-thread GC
proc initializeLibrary() {.exported.} =
  if not initialized.exchange(true):
    ## Every Nim library must call `<prefix>NimMain()` once
    libp2pNimMain()
  when declared(setupForeignThreadGc):
    setupForeignThreadGc()
  when declared(nimGC_setStackBottom):
    var locals {.volatile, noinit.}: pointer
    locals = addr(locals)
    nimGC_setStackBottom(locals)

### End of library setup
################################################################################

################################################################################
### Exported procs

proc libp2p_new(
    callback: Libp2pCallback, userData: pointer
): pointer {.dynlib, exportc, cdecl.} =
  ## Creates a new instance of the library's context

  initializeLibrary()

  ## Creates a new instance of libp2p.
  if isNil(callback):
    echo "error: missing callback in libp2p_new"
    return nil

  ## Create the Libp2p thread that will keep waiting for req from the Client thread.
  var ctx = libp2p_thread.createLibP2PThread().valueOr:
    let msg = "Error in createLibp2pThread: " & $error
    callback(RET_ERR.cint, addr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  ctx.userData = userData

  let appCallbacks = AppCallbacks()

  let retCode = handleRequest(
    ctx,
    RequestType.LIFECYCLE,
    LifecycleRequest.createShared(LifecycleMsgType.CREATE_LIBP2P, appCallbacks),
    callback,
    userData,
  )

  if retCode != RET_OK:
    return nil

  return ctx

proc libp2p_destroy(
    ctx: ptr LibP2PContext, callback: Libp2pCallback, userData: pointer
): cint {.dynlib, exportc.} =
  ## Destroys the Libp2p thread
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  libp2p_thread.destroyLibP2PThread(ctx).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, addr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  ## always need to invoke the callback although we don't retrieve value to the caller
  callback(RET_OK.cint, nil, 0, userData)

  return RET_OK.cint

proc libp2p_set_event_callback(
    ctx: ptr LibP2PContext, callback: Libp2pCallback, userData: pointer
) {.dynlib, exportc.} =
  ## Sets the callback for receiving asynchronous events

  initializeLibrary()
  ctx[].eventCallback = cast[pointer](callback)
  ctx[].eventUserData = userData

proc libp2p_hello(
    ctx: ptr LibP2PContext, callback: Libp2pCallback, userData: pointer
): cint {.dynlib, exportc.} =
  ## This is just to demonstrate how FFI works
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  handleRequest(
    ctx,
    RequestType.HELLO,
    HelloRequest.createShared(HelloMsgType.HELLO),
    callback,
    userData,
  ).cint

### End of exported procs
################################################################################

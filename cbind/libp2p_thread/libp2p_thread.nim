# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

# LibP2P Thread Manager
#
# This file defines the `LibP2PContext` and associated logic to manage the LibP2P thread.
# It sets up inter-thread communication via channels and signals, allowing the client
# thread to send requests to the LibP2P thread for processing.

{.pragma: exported, exportc, cdecl, raises: [].}
{.pragma: callback, cdecl, raises: [], gcsafe.}
{.passc: "-fPIC".}

import std/[options, atomics, os, net, locks]
import chronicles, chronos, chronos/threadsync, taskpools/channels_spsc_single, results
import
  ../[ffi_types, types],
  ./inter_thread_communication/libp2p_thread_request,
  ../../libp2p

# Context from the LibP2P thread, shared with the Client thread
type LibP2PContext* = object
  thread: Thread[(ptr LibP2PContext)] # The running thread that executes the LibP2P loop
  lock: Lock # Used to serialize access to the SP channel
  reqChannel: ChannelSPSCSingle[ptr LibP2PThreadRequest]
  reqSignal: ThreadSignalPtr # To notify the LibP2P Thread that a request is ready
  reqReceivedSignal: ThreadSignalPtr
    # To notify the Client thread that the request was received
  userData*: pointer
  eventCallback*: pointer
  eventUserData*: pointer
  running: Atomic[bool] # Used to stop the LibP2P thread loop

proc runLibP2P(ctx: ptr LibP2PContext) {.async: (raises: [CancelledError]).} =
  ## Main async loop of the LibP2P thread, processes incoming requests

  # This is the worker body. This runs the LibP2P instance
  # and attends library user requests

  var libp2p: LibP2P

  while true:
    try:
      await ctx.reqSignal.wait()
    except AsyncError as exc:
      error "libp2p thread async error", err = $exc.msg
      continue

    if not ctx.running.load:
      break

    # Trying to get a request from the libp2p requestor thread
    var request: ptr LibP2PThreadRequest
    let recvOk = ctx.reqChannel.tryRecv(request)
    if not recvOk:
      error "libp2p thread could not receive a request"
      continue

    # Handle the request
    asyncSpawn LibP2PThreadRequest.process(request, addr libp2p)

    let fireRes = ctx.reqReceivedSignal.fireSync()
    if fireRes.isErr():
      error "could not fireSync back to requester thread", error = fireRes.error

proc run(ctx: ptr LibP2PContext) {.thread.} =
  ## Thread entrypoint wrapper to start the async runLibP2P loop

  # Launch libp2p worker
  waitFor runLibP2P(ctx)

proc createLibP2PThread*(): Result[ptr LibP2PContext, string] =
  ## Initializes the LibP2P thread, sets up channels, signals, and launches the thread

  # This proc is called from the Client thread and it creates
  # the LibP2P working thread.
  var ctx = createShared(LibP2PContext, 1)
  ctx.reqSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqSignal ThreadSignalPtr")
  ctx.reqReceivedSignal = ThreadSignalPtr.new().valueOr:
    return err("couldn't create reqReceivedSignal ThreadSignalPtr")
  ctx.lock.initLock()

  ctx.running.store(true)

  try:
    createThread(ctx.thread, run, ctx)
  except ValueError, ResourceExhaustedError:
    # and freeShared for typed allocations!
    freeShared(ctx)

    return err("failed to create the LibP2P thread: " & getCurrentExceptionMsg())

  return ok(ctx)

proc destroyLibP2PThread*(ctx: ptr LibP2PContext): Result[void, string] =
  ## Gracefully shuts down the LibP2P thread and releases resources

  ctx.running.store(false)

  let signaledOnTime = ctx.reqSignal.fireSync().valueOr:
    return err("error in destroyLibP2PThread: " & $error)
  if not signaledOnTime:
    return err("failed to signal reqSignal on time in destroyLibP2PThread")

  joinThread(ctx.thread)
  ctx.lock.deinitLock()
  ?ctx.reqSignal.close()
  ?ctx.reqReceivedSignal.close()
  freeShared(ctx)

  return ok()

proc sendRequestInternal(
    ctx: ptr LibP2PContext, req: ptr LibP2PThreadRequest
): Result[void, string] =
  # This lock is only necessary while we use a SP Channel and while the signalling
  # between threads assumes that there aren't concurrent requests.
  # Rearchitecting the signaling + migrating to a MP Channel will allow us to receive
  # requests concurrently and spare us the need of locks
  ctx.lock.acquire()
  defer:
    ctx.lock.release()

  let sentOk = ctx.reqChannel.trySend(req)
  if not sentOk:
    let msg = "Couldn't send a request to the libp2p thread: " & $req[]
    deallocShared(req)
    return err(msg)

  let fireSyncRes = ctx.reqSignal.fireSync()
  if fireSyncRes.isErr():
    let msg = "failed fireSync: " & $fireSyncRes.error
    deallocShared(req)
    return err(msg)

  if fireSyncRes.get() == false:
    deallocShared(req)
    return err("Couldn't fireSync in time")

  let res = ctx.reqReceivedSignal.waitSync()
  if res.isErr():
    deallocShared(req)
    return err("Couldn't receive reqReceivedSignal signal")

  # Notice that in case of "ok", the deallocShared(req) is performed by the LibP2P Thread in the
  # process proc.
  ok()

template sendRequest(
    ctx: ptr LibP2PContext,
    reqType: RequestType,
    reqContent: pointer,
    userData: pointer,
    callbackKind: CallbackKind,
    callback: pointer = nil,
): Result[void, string] =
  let req = LibP2PThreadRequest.createShared(
    reqType, reqContent, callback, userData, callbackKind
  )
  sendRequestInternal(ctx, req)

proc sendRequestToLibP2PThread*(
    ctx: ptr LibP2PContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: Libp2pCallback,
    userData: pointer,
): Result[void, string] =
  ## Sends a request to the LibP2P thread, blocking until it is received
  sendRequest(
    ctx, reqType, reqContent, userData, CallbackKind.DEFAULT, cast[pointer](callback)
  )

proc sendRequestToLibP2PThread*(
    ctx: ptr LibP2PContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: PeerInfoCallback,
    userData: pointer,
): Result[void, string] =
  ## Sends a request to the LibP2P thread for peer-info callbacks
  sendRequest(
    ctx, reqType, reqContent, userData, CallbackKind.PEER_INFO, cast[pointer](callback)
  )

proc sendRequestToLibP2PThread*(
    ctx: ptr LibP2PContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: PeersCallback,
    callbackKind: CallbackKind,
    userData: pointer,
): Result[void, string] =
  ## Sends a request to the LibP2P thread for find-node callbacks
  sendRequest(ctx, reqType, reqContent, userData, callbackKind, cast[pointer](callback))

proc sendRequestToLibP2PThread*(
    ctx: ptr LibP2PContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: GetProvidersCallback,
    userData: pointer,
): Result[void, string] =
  ## Sends a request to the LibP2P thread for get-providers callbacks
  sendRequest(
    ctx,
    reqType,
    reqContent,
    userData,
    CallbackKind.GET_PROVIDERS,
    cast[pointer](callback),
  )

proc sendRequestToLibP2PThread*(
    ctx: ptr LibP2PContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: RandomRecordsCallback,
    userData: pointer,
): Result[void, string] =
  ## Sends a request to the LibP2P thread for kademlia random-records
  sendRequest(
    ctx,
    reqType,
    reqContent,
    userData,
    CallbackKind.RANDOM_RECORDS,
    cast[pointer](callback),
  )

proc sendRequestToLibP2PThread*(
    ctx: ptr LibP2PContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: ConnectionCallback,
    userData: pointer,
): Result[void, string] =
  ## Sends a request to the LibP2P thread for connection callbacks
  sendRequest(
    ctx, reqType, reqContent, userData, CallbackKind.CONNECTION, cast[pointer](callback)
  )

proc sendRequestToLibP2PThread*(
    ctx: ptr LibP2PContext,
    reqType: RequestType,
    reqContent: pointer,
    callback: Libp2pBufferCallback,
    callbackKind: CallbackKind,
    userData: pointer,
): Result[void, string] =
  ## Sends a request to the LibP2P thread for buffer callbacks
  sendRequest(ctx, reqType, reqContent, userData, callbackKind, cast[pointer](callback))

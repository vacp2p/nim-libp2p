# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# Thread Request Dispatcher
#
# This file defines the `LibP2PThreadRequest` type, which acts as a wrapper for all
# request messages handled by the libp2p thread. It supports multiple request types,
# delegating the logic to their respective processors.

import std/json, results
import chronos, chronos/threadsync
import
  ../../[ffi_types, types],
  ./requests/[libp2p_lifecycle_requests, libp2p_hello_requests],
  ../../../libp2p

# TODO: Add new request categories as needed
type RequestType* {.pure.} = enum
  LIFECYCLE
  HELLO

## Central request object passed to the LibP2P thread
type LibP2PThreadRequest* = object
  reqType: RequestType
  reqContent: pointer # pointer to the actual request object
  callback: Libp2pCallback
  userData: pointer

# Shared memory allocation for LibP2PThreadRequest
proc createShared*(
    T: type LibP2PThreadRequest,
    reqType: RequestType,
    reqContent: pointer,
    callback: Libp2pCallback,
    userData: pointer,
): ptr type T =
  var ret = createShared(T)
  ret[].reqType = reqType
  ret[].reqContent = reqContent
  ret[].callback = callback
  ret[].userData = userData
  return ret

# Handles responses of type Result[string, string] or Result[void, string]
# Converts the result into a C callback invocation with either RET_OK or RET_ERR
proc handleRes[T: string | void](
    res: Result[T, string], request: ptr LibP2PThreadRequest
) =
  ## Handles the Result responses, which can either be Result[string, string] or
  ## Result[void, string].

  defer:
    deallocShared(request)

  if res.isErr():
    foreignThreadGc:
      let msg = "libp2p error: handleRes fireSyncRes error: " & $res.error
      request[].callback(
        RET_ERR.cint, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
      )
    return

  foreignThreadGc:
    var msg: cstring = ""
    when T is string:
      msg = res.get().cstring()
    request[].callback(
      RET_OK.cint, unsafeAddr msg[0], cast[csize_t](len(msg)), request[].userData
    )
  return

# Dispatcher for processing the request based on its type
# Casts reqContent to the correct request struct and runs its `.process()` logic
proc process*(
    T: type LibP2PThreadRequest, request: ptr LibP2PThreadRequest, libp2p: ptr LibP2P
) {.async.} =
  let retFut =
    case request[].reqType
    of RequestType.LIFECYCLE:
      cast[ptr LifecycleRequest](request[].reqContent).process(libp2p)
    of RequestType.Hello:
      cast[ptr HelloRequest](request[].reqContent).process(libp2p)

  handleRes(await retFut, request)

# String representation of the request type
proc `$`*(self: LibP2PThreadRequest): string =
  return $self.reqType

# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

# Thread Request Example Implementation
#
# This file defines the `LifecycleRequest` type and its lifecycle, including memory
# management and request processing. This structure is used for communicating with the
# main thread, which is the one that runs LibP2P

import std/[json]
import chronos, results

import ../../../[types]
import ../../../../libp2p

type LifecycleMsgType* = enum
  CREATE_LIBP2P

type LifecycleRequest* = object
  operation: LifecycleMsgType
  appCallbacks: AppCallbacks

proc createLibp2p(appCallbacks: AppCallbacks): LibP2P =
  # TODO: implement
  LibP2P()

proc createShared*(
    T: type LifecycleRequest, op: LifecycleMsgType, appCallbacks: AppCallbacks = nil
): ptr type T =
  # TODO: Modify for your request's specific field initialization
  # TODO: Allocate parameters of GC'd types to the shared memory
  var ret = createShared(T)
  ret[].operation = op
  ret[].appCallbacks = appCallbacks
  return ret

proc destroyShared(self: ptr LifecycleRequest) =
  # TODO: Free any newly added fields here if you change the object structure
  # TODO: Deallocate parameters of GC'd types from the shared memory
  deallocShared(self)

proc process*(
    self: ptr LifecycleRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  # TODO: Implement the request logic for your new operation types
  case self.operation
  of CREATE_LIBP2P:
    libp2p[] = createLibp2p(self.appCallbacks)

  return ok("")

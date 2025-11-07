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
# This file defines the `HelloRequest` type and its lifecycle, including memory
# management and request processing. This structure is used for communicating between
# the Client and LibP2P threads

import std/[json]
import chronos, results
import ../../../types
import ../../../../libp2p

type HelloMsgType* = enum
  HELLO

type HelloRequest* = object
  operation: HelloMsgType

proc createShared*(T: type HelloRequest, op: HelloMsgType): ptr type T =
  var ret = createShared(T)
  ret[].operation = op

  return ret

proc destroyShared(self: ptr HelloRequest) =
  deallocShared(self)

proc process*(
    self: ptr HelloRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async.} =
  defer:
    destroyShared(self)

  case self.operation
  of HELLO:
    return ok("Hello World")

  return ok("")

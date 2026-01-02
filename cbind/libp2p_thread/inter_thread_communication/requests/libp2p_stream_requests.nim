# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/tables
import chronos, results
import ../../../[alloc, ffi_types, types]
import ../../../../libp2p

type StreamMsgType* = enum
  DIAL
  CLOSE
  CLOSE_WITH_EOF
  RELEASE

type StreamRequest* = object
  operation*: StreamMsgType
  peerId: cstring
  proto: cstring
  connHandle: ptr Libp2pStream

proc createShared*(
    T: type StreamRequest,
    op: StreamMsgType,
    peerId: cstring = "",
    proto: cstring = "",
    conn: ptr Libp2pStream = nil,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  ret[].proto = proto.alloc()
  ret[].connHandle = conn
  ret

proc destroyShared(self: ptr StreamRequest) =
  deallocShared(self[].peerId)
  deallocShared(self[].proto)
  deallocShared(self)

proc processDial*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[ptr Libp2pStream, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let peerId = PeerId.init($self[].peerId).valueOr:
    return err($error)
  let conn =
    try:
      await libp2p.switch.dial(peerId, $self[].proto)
    except DialFailedError as exc:
      return err(exc.msg)

  let handle = cast[ptr Libp2pStream](createShared(Libp2pStream, 1))
  handle[].conn = cast[pointer](conn)
  libp2p[].connections[handle] = conn

  return ok(handle)

proc processClose*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let handle = self[].connHandle
  if handle.isNil():
    return err("invalid connection handle")

  let conn = libp2p[].connections.getOrDefault(handle, nil)
  if conn.isNil():
    return err("unknown connection handle")

  case self.operation
  of CLOSE:
    await conn.close()
  of CLOSE_WITH_EOF:
    await conn.closeWithEOF()
  else:
    raiseAssert "unsupported operation"

  return ok("")

proc processRelease*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let handle = self[].connHandle
  if handle.isNil():
    return err("invalid connection handle")

  if not libp2p[].connections.hasKey(handle):
    return err("unknown connection handle")

  libp2p[].connections.del(handle)
  deallocShared(handle)

  return ok("")

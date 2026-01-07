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
  WRITE
  WRITELP
  READEXACTLY
  READLP

type StreamRequest* = object
  operation*: StreamMsgType
  peerId: cstring
  proto: cstring
  connHandle: ptr Libp2pStream
  data: SharedSeq[byte] ## Only used for WRITE/WRITELP
  readLen: csize_t ## Only used for READEXACTLY
  maxSize: int64 ## Only used for READLP

type ReadResponse* = object
  data*: ptr byte
  dataLen*: csize_t

proc createShared*(
    T: type StreamRequest,
    op: StreamMsgType,
    peerId: cstring = "",
    proto: cstring = "",
    conn: ptr Libp2pStream = nil,
    data: ptr byte = nil,
    dataLen: csize_t = 0,
    readLen: csize_t = 0,
    maxSize: int64 = -1,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  ret[].proto = proto.alloc()
  ret[].connHandle = conn
  ret[].data = allocSharedSeqFromCArray(data, dataLen.int)
  ret[].readLen = readLen
  ret[].maxSize = maxSize
  ret

proc destroyShared(self: ptr StreamRequest) =
  deallocShared(self[].peerId)
  deallocShared(self[].proto)
  deallocSharedSeq(self[].data)
  deallocShared(self)

proc deallocReadResponse*(res: ptr ReadResponse) =
  if res.isNil():
    return

  if res[].data != nil:
    deallocShared(res[].data)

  deallocShared(res)

proc allocReadResponse*(data: seq[byte]): ptr ReadResponse =
  let res = cast[ptr ReadResponse](createShared(ReadResponse, 1))
  if data.len == 0:
    res[].data = nil
    res[].dataLen = 0
    return res

  res[].dataLen = data.len.csize_t
  res[].data = cast[ptr byte](allocShared(data.len))
  copyMem(res[].data, addr data[0], data.len)
  res

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

proc processWrite*(
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

  try:
    case self.operation
    of WRITE:
      await conn.write(self[].data.toSeq())
    of WRITELP:
      await conn.writeLp(self[].data.toSeq())
    else:
      raiseAssert "unsupported operation in processWrite"
  except LPStreamError as exc:
    return err(exc.msg)

  return ok("")

proc processRead*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[ptr ReadResponse, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let handle = self[].connHandle
  if handle.isNil():
    return err("invalid connection handle")

  let conn = libp2p[].connections.getOrDefault(handle, nil)
  if conn.isNil():
    return err("unknown connection handle")

  try:
    case self.operation
    of READEXACTLY:
      if self[].readLen > csize_t(int.high):
        return err("read length too large")
      let expected = int(self[].readLen)
      if expected == 0:
        return ok(allocReadResponse(@[]))
      var buf = newSeqUninit[byte](expected)
      await conn.readExactly(addr buf[0], expected)
      return ok(allocReadResponse(buf))
    of READLP:
      if self[].maxSize > int64(int.high) or self[].maxSize < int64(int.low):
        return err("maxSize out of range")
      let data = await conn.readLp(int(self[].maxSize))
      return ok(allocReadResponse(data))
    else:
      raiseAssert "unsupported operation in processRead"
  except LPStreamError as exc:
    return err(exc.msg)

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/tables
import chronos, results
import ../../../[alloc, ffi_types, types]
import ../../../../libp2p

type StreamMsgType* = enum
  DIAL
  DIAL_CIRCUIT_RELAY
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
  multiaddr: cstring
  proto: cstring
  connHandle: ptr Libp2pStream
  data: SharedSeq[byte] ## Only used for WRITE/WRITELP
  readLen: csize_t ## Only used for READEXACTLY
  maxSize: int64 ## Only used for READLP

proc createShared*(
    T: type StreamRequest,
    op: StreamMsgType,
    peerId: cstring = "",
    multiaddr: cstring = "",
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
  ret[].multiaddr = multiaddr.alloc()
  ret[].proto = proto.alloc()
  ret[].connHandle = conn
  ret[].data = allocSharedSeqFromCArray(data, dataLen.int)
  ret[].readLen = readLen
  ret[].maxSize = maxSize
  ret

proc destroyShared*(self: ptr StreamRequest) =
  deallocShared(self[].peerId)
  deallocShared(self[].multiaddr)
  deallocShared(self[].proto)
  deallocSharedSeq(self[].data)
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

proc processDialCircuitRelay*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[ptr Libp2pStream, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let dstPeerId = PeerId.init($self[].peerId).valueOr:
    return err($error)
  let relayCircuitAddr = MultiAddress.init($self[].multiaddr).valueOr:
    return err($error)

  let conn =
    try:
      await libp2p.switch.dial(dstPeerId, @[relayCircuitAddr], $self[].proto)
    except DialFailedError as exc:
      return err(exc.msg)

  let handle = cast[ptr Libp2pStream](createShared(Libp2pStream, 1))
  handle[].conn = cast[pointer](conn)
  libp2p[].connections[handle] = conn
  return ok(handle)

proc processClose*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
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

  return ok()

proc processRelease*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let handle = self[].connHandle
  if handle.isNil():
    return err("invalid connection handle")

  if not libp2p[].connections.hasKey(handle):
    return err("unknown connection handle")

  # For incoming custom-protocol streams, release completes the Nim protocol
  # handler that has been waiting for C to finish its callback chain.
  if libp2p[].streamReleaseWaiters.hasKey(handle):
    let releaseWaiter =
      try:
        libp2p[].streamReleaseWaiters[handle]
      except KeyError:
        raiseAssert "checked with hasKey"
    libp2p[].streamReleaseWaiters.del(handle)
    if not releaseWaiter.finished:
      releaseWaiter.complete()

  libp2p[].connections.del(handle)
  deallocShared(handle)

  return ok()

proc processWrite*(
    self: ptr StreamRequest, libp2p: ptr LibP2P
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
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

  return ok()

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

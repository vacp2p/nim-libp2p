# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/tables
import chronos, results
import ../../../[alloc, ffi_types, types]
import ../../../../libp2p
import ../../../../libp2p/protocols/protocol

type ProtocolMsgType* = enum
  MOUNT

type ProtocolRequest* = object
  operation*: ProtocolMsgType
  ctx: pointer
  proto: cstring
  handler: Libp2pProtocolHandler
  protocolUserData: pointer

proc createShared*(
    T: type ProtocolRequest,
    op: ProtocolMsgType,
    ctx: pointer,
    proto: cstring,
    handler: Libp2pProtocolHandler,
    protocolUserData: pointer,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].ctx = ctx
  ret[].proto = proto.alloc()
  ret[].handler = handler
  ret[].protocolUserData = protocolUserData
  ret

proc destroyShared*(self: ptr ProtocolRequest) =
  deallocShared(self[].proto)
  deallocShared(self)

proc processMount*(
    self: ptr ProtocolRequest, libp2p: ptr LibP2P
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  if self[].proto.isNil() or self[].proto[0] == '\0':
    return err("proto is empty")
  if self[].handler.isNil():
    return err("handler is nil")
  if libp2p.isNil() or libp2p[].switch.isNil():
    return err("libp2p switch is not initialized")

  let proto = $self[].proto
  let peerInfo = libp2p[].switch.peerInfo
  if libp2p[].customProtocols.hasKey(proto) or proto in peerInfo.protocols:
    return err("protocol already mounted: " & proto)

  let
    ctx = self[].ctx
    handler = self[].handler
    protocolUserData = self[].protocolUserData

  proc handle(
      stream: Stream, selectedProto: string
  ) {.async: (raises: [CancelledError]).} =
    let streamHandle = cast[ptr Libp2pStream](createShared(Libp2pStream, 1))
    streamHandle[].stream = cast[pointer](stream)
    # The C handler is callback-based and returns before read/write callbacks
    # finish. Waiting here prevents multistream from closing the incoming stream
    # until C explicitly releases its stream handle.
    let releaseWaiter =
      Future[void].Raising([CancelledError]).init("cbind custom protocol release")

    libp2p[].streams[streamHandle] = stream
    libp2p[].streamReleaseWaiters[streamHandle] = releaseWaiter

    try:
      foreignThreadGc:
        let protoPtr =
          if selectedProto.len > 0:
            cast[ptr cchar](unsafeAddr selectedProto[0])
          else:
            cast[ptr cchar](nil)
        handler(
          ctx,
          streamHandle,
          protoPtr,
          cast[csize_t](selectedProto.len),
          protocolUserData,
        )

      await releaseWaiter
    finally:
      if libp2p[].streamReleaseWaiters.hasKey(streamHandle):
        libp2p[].streamReleaseWaiters.del(streamHandle)

      if libp2p[].streams.hasKey(streamHandle):
        libp2p[].streams.del(streamHandle)
        deallocShared(streamHandle)

  let mountedProtocol = LPProtocol.new(codecs = @[proto], handler = handle)
  await mountedProtocol.start()

  try:
    libp2p[].switch.mount(mountedProtocol)
  except LPError as exc:
    return err(exc.msg)

  libp2p[].customProtocols[proto] = mountedProtocol
  ok()

proc process*(
    self: ptr ProtocolRequest, libp2p: ptr LibP2P
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  await self.processMount(libp2p)

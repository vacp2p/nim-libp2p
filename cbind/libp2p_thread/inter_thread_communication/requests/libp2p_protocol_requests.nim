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
  operation: ProtocolMsgType
  protocol: cstring
  handler: Libp2pProtocolHandler
  handlerUserData: pointer
  ctx: pointer

type ProtocolHandlerThreadArgs = object
  handler: Libp2pProtocolHandler
  ctx: pointer
  stream: ptr Libp2pStream
  protocol: cstring
  userData: pointer

proc runProtocolHandler(args: ProtocolHandlerThreadArgs) {.thread.} =
  if not args.handler.isNil():
    args.handler(
      cast[ptr Libp2pCtx](args.ctx),
      args.stream,
      args.protocol,
      args.userData,
    )

  if not args.protocol.isNil():
    deallocShared(args.protocol)

proc createShared*(
    T: type ProtocolRequest,
    op: ProtocolMsgType,
    protocol: cstring,
    handler: Libp2pProtocolHandler,
    handlerUserData: pointer,
    ctx: pointer,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].protocol = protocol.alloc()
  ret[].handler = handler
  ret[].handlerUserData = handlerUserData
  ret[].ctx = ctx
  ret

proc destroyShared(self: ptr ProtocolRequest) =
  if not self[].protocol.isNil():
    deallocShared(self[].protocol)
  deallocShared(self)

proc process*(
    self: ptr ProtocolRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  case self.operation
  of MOUNT:
    if self[].handler.isNil():
      return err("protocol handler is nil")
    if self[].protocol.isNil() or self[].protocol[0] == '\0':
      return err("protocol is empty")

    let proto = $self[].protocol
    if libp2p[].protocolHandlers.hasKey(proto):
      return err("protocol already mounted: " & proto)

    let handler = self[].handler
    let handlerUserData = self[].handlerUserData
    let ctx = self[].ctx

    let lpHandler = proc(
        conn: Connection, protoStr: string
    ): Future[void] {.async: (raises: [CancelledError]).} =
      let handle = cast[ptr Libp2pStream](createShared(Libp2pStream, 1))
      handle[].conn = cast[pointer](conn)
      libp2p[].connections[handle] = conn

      let args = ProtocolHandlerThreadArgs(
        handler: handler,
        ctx: ctx,
        stream: handle,
        protocol: protoStr.alloc(),
        userData: handlerUserData,
      )

      echo "TODO"

    let protoImpl = LPProtocol.new(codecs = @[proto], handler = lpHandler)
    try:
      libp2p[].switch.mount(protoImpl)
    except LPError:
      raiseAssert "TODO"
      
    libp2p[].protocolHandlers[proto] = ProtocolHandlerEntry(
      handler: handler,
      userData: handlerUserData,
      ctx: ctx,
      protocol: proto,
      protocolImpl: protoImpl,
    )

  return ok("")

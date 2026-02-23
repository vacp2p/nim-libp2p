# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

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
  ./libp2p_thread/inter_thread_communication/requests/[
    libp2p_lifecycle_requests, libp2p_peer_manager_requests, libp2p_pubsub_requests,
    libp2p_kademlia_requests, libp2p_stream_requests,
  ],
  ../libp2p,
  ../libp2p/crypto/crypto,
  ../libp2p/crypto/curve25519
################################################################################
### Not-exported components
################################################################################

template checkLibParams*(ctx: ptr LibP2PContext, callback: pointer, userData: pointer) =
  ## This template checks common parameters passed to exported functions
  if isNil(ctx):
    return RET_ERR.cint

  ctx[].userData = userData

  if isNil(callback):
    return RET_MISSING_CALLBACK.cint

template failWithMsg(callback: Libp2pCallback, userData: pointer, msg: string) =
  let localMsg = msg
  let msgLen = cast[csize_t](len(localMsg))
  var msgPtr: ptr cchar = nil
  if msgLen > 0:
    msgPtr = cast[ptr cchar](addr localMsg[0])
  callback(RET_ERR.cint, msgPtr, msgLen, userData)
  return RET_ERR.cint

template failWithBufferMsg(
    callback: Libp2pBufferCallback, userData: pointer, msg: string
) =
  let localMsg = msg
  let msgLen = cast[csize_t](len(localMsg))
  var msgPtr: ptr cchar = nil
  if msgLen > 0:
    msgPtr = cast[ptr cchar](addr localMsg[0])
  callback(RET_ERR.cint, nil, 0, msgPtr, msgLen, userData)
  return RET_ERR.cint

template failIfConnNil(
    conn: ptr Libp2pStream, callback: Libp2pCallback, userData: pointer, msg: string
) =
  if conn.isNil():
    failWithMsg(callback, userData, msg)

template failIfConnNil(
    conn: ptr Libp2pStream,
    callback: Libp2pBufferCallback,
    userData: pointer,
    msg: string,
) =
  if conn.isNil():
    failWithBufferMsg(callback, userData, msg)

template failIfDataMissing(
    data: ptr byte, dataLen: csize_t, callback: Libp2pCallback, userData: pointer
) =
  if dataLen > 0 and data.isNil():
    failWithMsg(callback, userData, "data is not set")

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

proc initializeLibrary() {.exported.} =
  ## Initializes the Nim runtime and foreign-thread GC
  if not initialized.exchange(true):
    # Every Nim library must call `<prefix>NimMain()` once
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

proc libp2p_mix_generate_priv_key(
    outKey: ptr MixCurve25519Key
) {.dynlib, exportc, cdecl.} =
  initializeLibrary()

  doAssert(not outKey.isNil(), "outKey is nil")

  var rng = newRng()
  let priv = Curve25519Key.random(rng[])

  for i in 0 ..< Curve25519KeySize:
    outKey[].bytes[i] = priv[i]

proc libp2p_mix_public_key(
    inKey: MixCurve25519Key, outKey: ptr MixCurve25519Key
) {.dynlib, exportc, cdecl.} =
  initializeLibrary()

  doAssert(not outKey.isNil(), "outKey is nil")

  var priv: Curve25519Key
  for i in 0 ..< Curve25519KeySize:
    priv[i] = inKey.bytes[i]

  let pub = public(priv)
  for i in 0 ..< Curve25519KeySize:
    outKey[].bytes[i] = pub[i]

proc libp2p_create_cid(
    version: cuint,
    multicodec: cstring,
    hash: cstring,
    data: ptr byte,
    dataLen: csize_t,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()

  if callback.isNil():
    return RET_MISSING_CALLBACK.cint

  if multicodec.isNil() or hash.isNil():
    failWithMsg(callback, userData, "multicodec or hash is not set")

  failIfDataMissing(data, dataLen, callback, userData)

  var payload: seq[byte]
  if dataLen == 0:
    payload = @[]
  else:
    payload = newSeq[byte](int(dataLen))
    copyMem(addr payload[0], data, int(dataLen))

  let cidVer =
    case int(version)
    of 0:
      CIDv0
    of 1:
      CIDv1
    else:
      failWithMsg(callback, userData, "cid version must be 0 or 1")

  let mc = MultiCodec.codec($multicodec)

  let mhRes = MultiHash.digest($hash, payload)
  let mh = mhRes.valueOr:
    failWithMsg(callback, userData, "multihash error: " & $mhRes.error)

  let cidRes = Cid.init(cidVer, mc, mh)
  let cid = cidRes.valueOr:
    failWithMsg(callback, userData, "cid init error: " & $cidRes.error)

  let cidStr = $cid
  callback(RET_OK.cint, addr cidStr[0], cast[csize_t](len(cidStr)), userData)
  RET_OK.cint

proc libp2p_new_private_key(
    scheme: PKScheme, callback: Libp2pBufferCallback, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  ## Creates a new private key

  initializeLibrary()

  let key = PrivateKey.random(scheme, newRng()[]).valueOr:
    echo "Could not generate private key"
    return RET_ERR.cint

  let keyData = key.getBytes().valueOr:
    echo "Could not get bytes for private key"
    return RET_ERR.cint

  foreignThreadGc:
    let dataPtr =
      if keyData.len > 0:
        unsafeAddr keyData[0]
      else:
        nil

    callback(
      RET_OK.cint,
      dataPtr,
      csize_t(keyData.len()),
      cast[ptr cchar](nil),
      csize_t(0),
      userData,
    )
  return RET_OK.cint

proc libp2p_new(
    config: ptr Libp2pConfig, callback: Libp2pCallback, userData: pointer
): pointer {.dynlib, exportc, cdecl.} =
  ## Creates a new instance of the library's context

  initializeLibrary()

  ## Creates a new instance of libp2p.
  if isNil(callback):
    echo "error: missing callback in libp2p_new"
    return nil

  ## Create the Libp2p thread that will keep waiting for req from the Client thread.
  var ctx = libp2p_thread.createLibP2PThread().valueOr:
    let msg = "error in createLibp2pThread: " & $error
    callback(RET_ERR.cint, addr msg[0], cast[csize_t](len(msg)), userData)
    return nil

  ctx.userData = userData

  let appCallbacks = AppCallbacks()

  let retCode = handleRequest(
    ctx,
    RequestType.LIFECYCLE,
    LifecycleRequest.createShared(LifecycleMsgType.CREATE_LIBP2P, appCallbacks, config),
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
    failWithMsg(callback, userData, "libp2p error: " & $error)

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

proc libp2p_start(
    ctx: ptr LibP2PContext, callback: Libp2pCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  handleRequest(
    ctx,
    RequestType.LIFECYCLE,
    LifecycleRequest.createShared(LifecycleMsgType.START_NODE),
    callback,
    userData,
  ).cint

proc libp2p_stop(
    ctx: ptr LibP2PContext, callback: Libp2pCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  handleRequest(
    ctx,
    RequestType.LIFECYCLE,
    LifecycleRequest.createShared(LifecycleMsgType.STOP_NODE),
    callback,
    userData,
  ).cint

proc libp2p_connect(
    ctx: ptr LibP2PContext,
    peerId: cstring,
    multiaddrs: ptr cstring,
    multiaddrsLen: csize_t,
    timeoutMs: int64,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  handleRequest(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(
      PeerManagementMsgType.CONNECT,
      peerId,
      multiaddrs,
      multiaddrsLen,
      if timeoutMs <= 0:
        InfiniteDuration
      else:
        chronos.milliseconds(timeoutMs),
    ),
    callback,
    userData,
  ).cint

proc libp2p_disconnect(
    ctx: ptr LibP2PContext, peerId: cstring, callback: Libp2pCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  handleRequest(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(
      PeerManagementMsgType.DISCONNECT, peerId = peerId
    ),
    callback,
    userData,
  ).cint

proc libp2p_peerinfo(
    ctx: ptr LibP2PContext, callback: PeerInfoCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(PeerManagementMsgType.PEER_INFO),
    callback,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, addr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  return RET_OK.cint

proc fromUint32*(T: typedesc[Direction], dir: uint32): Result[T, string] =
  case dir
  of uint32(Direction.In):
    ok(Direction.In)
  of uint32(Direction.Out):
    ok(Direction.Out)
  else:
    err("invalid direction")

proc libp2p_connected_peers(
    ctx: ptr LibP2PContext, dir: uint32, callback: PeersCallback, userData: pointer
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  let direction = Direction.fromUint32(dir).valueOr:
    let msg = "invalid direction: " & $dir
    callback(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.PEER_MANAGER,
    PeerManagementRequest.createShared(
      PeerManagementMsgType.CONNECTED_PEERS, direction = direction
    ),
    callback,
    CallbackKind.PEERS,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  return RET_OK.cint

proc libp2p_dial(
    ctx: ptr LibP2PContext,
    peerId: cstring,
    proto: cstring,
    callback: ConnectionCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(StreamMsgType.DIAL, peerId = peerId, proto = proto),
    callback,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  return RET_OK.cint

proc libp2p_mix_dial(
    ctx: ptr LibP2PContext,
    peerId: cstring,
    multiaddr: cstring,
    proto: cstring,
    callback: ConnectionCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if peerId.isNil() or multiaddr.isNil() or proto.isNil():
    let msg = "peerId, multiaddr, or proto is nil"
    callback(RET_ERR.cint, nil, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(
      StreamMsgType.MIX_DIAL, peerId = peerId, multiaddr = multiaddr, proto = proto
    ),
    callback,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  return RET_OK.cint

proc libp2p_mix_dial_with_reply(
    ctx: ptr LibP2PContext,
    peerId: cstring,
    multiaddr: cstring,
    proto: cstring,
    expectReply: cint,
    numSurbs: cuint,
    callback: ConnectionCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if peerId.isNil() or multiaddr.isNil() or proto.isNil():
    let msg = "peerId, multiaddr, or proto is nil"
    callback(RET_ERR.cint, nil, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  let expect = expectReply != 0
  let surbs = (if numSurbs > high(uint8).cuint: high(uint8).cuint
  else: numSurbs)

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(
      StreamMsgType.MIX_DIAL,
      peerId = peerId,
      multiaddr = multiaddr,
      proto = proto,
      mixExpectReply = expect,
      mixNumSurbs = surbs.uint8,
    ),
    callback,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  return RET_OK.cint

proc libp2p_mix_register_dest_read_behavior(
    ctx: ptr LibP2PContext,
    proto: cstring,
    behavior: MixReadBehaviorKind,
    sizeParam: cuint,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if proto.isNil():
    let msg = "proto is nil"
    callback(RET_ERR.cint, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(
      StreamMsgType.MIX_REGISTER_DEST_READ,
      proto = proto,
      mixReadBehaviorKind = behavior.cint,
      mixReadBehaviorParam = sizeParam.cint,
    ),
    callback,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  return RET_OK.cint

proc libp2p_mix_set_node_info(
    ctx: ptr LibP2PContext,
    multiaddr: cstring,
    mixPrivKey: MixCurve25519Key,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)
  if multiaddr.isNil():
    failWithMsg(callback, userData, "multiaddr is nil")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(
      StreamMsgType.MIX_SET_NODE_INFO,
      multiaddr = multiaddr,
      data = cast[ptr byte](unsafeAddr mixPrivKey.bytes[0]),
      dataLen = Curve25519KeySize.csize_t,
    ),
    callback,
    userData,
  ).isOkOr:
    failWithMsg(callback, userData, "libp2p error: " & $error)

  RET_OK.cint

proc libp2p_mix_nodepool_add(
    ctx: ptr LibP2PContext,
    peerId: cstring,
    multiaddr: cstring,
    mixPubKey: MixCurve25519Key,
    libp2pPubKey: MixSecp256k1PubKey,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if peerId.isNil():
    failWithMsg(callback, userData, "peerId is nil")
  if multiaddr.isNil():
    failWithMsg(callback, userData, "multiaddr is nil")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(
      StreamMsgType.MIX_NODEPOOL_ADD,
      peerId = peerId,
      multiaddr = multiaddr,
      mixPubKey = mixPubKey,
      libp2pPubKey = libp2pPubKey,
    ),
    callback,
    userData,
  ).isOkOr:
    failWithMsg(callback, userData, "libp2p error: " & $error)

  RET_OK.cint

proc libp2p_public_key(
    ctx: ptr LibP2PContext, callback: Libp2pBufferCallback, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.LIFECYCLE,
    LifecycleRequest.createShared(LifecycleMsgType.GET_PUBLIC_KEY),
    callback,
    CallbackKind.READ,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  return RET_OK.cint

proc libp2p_stream_readExactly(
    ctx: ptr LibP2PContext,
    conn: ptr Libp2pStream,
    dataLen: csize_t,
    callback: Libp2pBufferCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  failIfConnNil(conn, callback, userData, "connection is not set 1")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(
      StreamMsgType.READEXACTLY, conn = conn, readLen = dataLen
    ),
    callback,
    CallbackKind.READ,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  return RET_OK.cint

proc libp2p_stream_readLp(
    ctx: ptr LibP2PContext,
    conn: ptr Libp2pStream,
    maxSize: int64,
    callback: Libp2pBufferCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  failIfConnNil(conn, callback, userData, "connection is not set")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(StreamMsgType.READLP, conn = conn, maxSize = maxSize),
    callback,
    CallbackKind.READ,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  return RET_OK.cint

proc libp2p_stream_write(
    ctx: ptr LibP2PContext,
    conn: ptr Libp2pStream,
    data: ptr byte,
    dataLen: csize_t,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  failIfConnNil(conn, callback, userData, "connection is not set")

  failIfDataMissing(data, dataLen, callback, userData)

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(
      StreamMsgType.WRITE, conn = conn, data = data, dataLen = dataLen
    ),
    callback,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, msg[0].addr, cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  return RET_OK.cint

proc libp2p_stream_writeLp(
    ctx: ptr LibP2PContext,
    conn: ptr Libp2pStream,
    data: ptr byte,
    dataLen: csize_t,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  failIfConnNil(conn, callback, userData, "connection is not set")

  failIfDataMissing(data, dataLen, callback, userData)

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(
      StreamMsgType.WRITELP, conn = conn, data = data, dataLen = dataLen
    ),
    callback,
    userData,
  ).isOkOr:
    failWithMsg(callback, userData, "libp2p error: " & $error)

  return RET_OK.cint

proc libp2p_stream_close(
    ctx: ptr LibP2PContext,
    conn: ptr Libp2pStream,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  failIfConnNil(conn, callback, userData, "connection is not set")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(StreamMsgType.CLOSE, conn = conn),
    callback,
    userData,
  ).isOkOr:
    failWithMsg(callback, userData, "libp2p error: " & $error)

  return RET_OK.cint

proc libp2p_stream_closeWithEOF(
    ctx: ptr LibP2PContext,
    conn: ptr Libp2pStream,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  failIfConnNil(conn, callback, userData, "connection is not set")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(StreamMsgType.CLOSE_WITH_EOF, conn = conn),
    callback,
    userData,
  ).isOkOr:
    failWithMsg(callback, userData, "libp2p error: " & $error)

  return RET_OK.cint

proc libp2p_stream_release(
    ctx: ptr LibP2PContext,
    conn: ptr Libp2pStream,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  failIfConnNil(conn, callback, userData, "connection is not set")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.STREAM,
    StreamRequest.createShared(StreamMsgType.RELEASE, conn = conn),
    callback,
    userData,
  ).isOkOr:
    failWithMsg(callback, userData, "libp2p error: " & $error)

  return RET_OK.cint

proc libp2p_gossipsub_publish(
    ctx: ptr LibP2PContext,
    topic: cstring,
    data: ptr byte,
    dataLen: csize_t,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  handleRequest(
    ctx,
    RequestType.PUBSUB,
    PubSubRequest.createShared(
      PubSubMsgType.PUBLISH, topic, data = data, dataLen = dataLen
    ),
    callback,
    userData,
  ).cint

proc libp2p_gossipsub_subscribe(
    ctx: ptr LibP2PContext,
    topic: cstring,
    topicHandler: PubsubTopicHandler,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  handleRequest(
    ctx,
    RequestType.PUBSUB,
    PubSubRequest.createShared(
      PubSubMsgType.SUBSCRIBE, topic, topicHandler, topicUserData = userData
    ),
    callback,
    userData,
  ).cint

proc libp2p_gossipsub_unsubscribe(
    ctx: ptr LibP2PContext,
    topic: cstring,
    topicHandler: PubsubTopicHandler,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  handleRequest(
    ctx,
    RequestType.PUBSUB,
    PubSubRequest.createShared(
      PubSubMsgType.UNSUBSCRIBE, topic, topicHandler, topicUserData = userData
    ),
    callback,
    userData,
  ).cint

#[
proc libp2p_gossipsub_add_validator(
    ctx: ptr LibP2PContext,
    topics: ptr cstring,
    topicsLen: csize_t,
    hook: PubsubValidatorHandler,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  handleRequest(
    ctx,
    RequestType.PUBSUB,
    PubSubRequest.createShared(
      PubSubMsgType.ADD_VALIDATOR, topics = topics, topicsLen = topicsLen, hook = hook
    ),
    callback,
    userData,
  ).cint

proc libp2p_gossipsub_remove_validator(
    ctx: ptr LibP2PContext,
    topics: ptr cstring,
    topicsLen: csize_t,
    hook: PubsubValidatorHandler,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  handleRequest(
    ctx,
    RequestType.PUBSUB,
    PubSubRequest.createShared(
      PubSubMsgType.REMOVE_VALIDATOR,
      topics = topics,
      topicsLen = topicsLen,
      hook = hook,
    ),
    callback,
    userData,
  ).cint
]#

proc libp2p_kad_find_node(
    ctx: ptr LibP2PContext, peerId: cstring, callback: PeersCallback, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if peerId.isNil():
    let msg = "peerId is nil"
    callback(RET_ERR.cint, nil, 0, addr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.KADEMLIA,
    KademliaRequest.createShared(KademliaMsgType.FIND_NODE, peerId = peerId),
    callback,
    CallbackKind.PEERS,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, 0, addr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  RET_OK.cint

proc libp2p_kad_put_value(
    ctx: ptr LibP2PContext,
    key: ptr byte,
    keyLen: csize_t,
    value: ptr byte,
    valueLen: csize_t,
    callback: Libp2pCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if key.isNil() or keyLen == 0:
    failWithMsg(callback, userData, "key is not set")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.KADEMLIA,
    KademliaRequest.createShared(
      KademliaMsgType.PUT_VALUE,
      key = key,
      keyLen = keyLen,
      value = value,
      valueLen = valueLen,
    ),
    callback,
    userData,
  ).isOkOr:
    failWithMsg(callback, userData, "libp2p error: " & $error)

  RET_OK.cint

proc libp2p_kad_get_value(
    ctx: ptr LibP2PContext,
    key: ptr byte,
    keyLen: csize_t,
    quorumOverride: cint,
    callback: Libp2pBufferCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if key.isNil() or keyLen == 0:
    failWithBufferMsg(callback, userData, "key is not set")

  if quorumOverride == 0:
    failWithBufferMsg(callback, userData, "quorum cannot be 0")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.KADEMLIA,
    KademliaRequest.createShared(
      KademliaMsgType.GET_VALUE,
      key = key,
      keyLen = keyLen,
      quorumOverride = quorumOverride,
    ),
    callback,
    CallbackKind.GET_VALUE,
    userData,
  ).isOkOr:
    failWithBufferMsg(callback, userData, "libp2p error: " & $error)

  RET_OK.cint

proc libp2p_kad_add_provider(
    ctx: ptr LibP2PContext, cid: cstring, callback: Libp2pCallback, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if cid.isNil():
    failWithMsg(callback, userData, "cid is nil")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.KADEMLIA,
    KademliaRequest.createShared(KademliaMsgType.ADD_PROVIDER, cid = cid),
    callback,
    userData,
  ).isOkOr:
    failWithMsg(callback, userData, "libp2p error: " & $error)

  RET_OK.cint

proc libp2p_kad_start_providing(
    ctx: ptr LibP2PContext, cid: cstring, callback: Libp2pCallback, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if cid.isNil():
    failWithMsg(callback, userData, "cid is nil")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.KADEMLIA,
    KademliaRequest.createShared(KademliaMsgType.START_PROVIDING, cid = cid),
    callback,
    userData,
  ).isOkOr:
    failWithMsg(callback, userData, "libp2p error: " & $error)

  RET_OK.cint

proc libp2p_kad_stop_providing(
    ctx: ptr LibP2PContext, cid: cstring, callback: Libp2pCallback, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if cid.isNil():
    failWithMsg(callback, userData, "cid is nil")

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.KADEMLIA,
    KademliaRequest.createShared(KademliaMsgType.STOP_PROVIDING, cid = cid),
    callback,
    userData,
  ).isOkOr:
    failWithMsg(callback, userData, "libp2p error: " & $error)

  RET_OK.cint

proc libp2p_kad_get_providers(
    ctx: ptr LibP2PContext,
    cid: cstring,
    callback: GetProvidersCallback,
    userData: pointer,
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  if cid.isNil():
    let msg = "cid is nil"
    callback(RET_ERR.cint, nil, 0, addr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.KADEMLIA,
    KademliaRequest.createShared(KademliaMsgType.GET_PROVIDERS, cid = cid),
    callback,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, 0, addr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  RET_OK.cint

proc libp2p_kad_random_records(
    ctx: ptr LibP2PContext, callback: RandomRecordsCallback, userData: pointer
): cint {.dynlib, exportc, cdecl.} =
  initializeLibrary()
  checkLibParams(ctx, callback, userData)

  libp2p_thread.sendRequestToLibP2PThread(
    ctx,
    RequestType.KADEMLIA,
    KademliaRequest.createShared(KademliaMsgType.RANDOM_RECORDS),
    callback,
    userData,
  ).isOkOr:
    let msg = "libp2p error: " & $error
    callback(RET_ERR.cint, nil, 0, addr msg[0], cast[csize_t](len(msg)), userData)
    return RET_ERR.cint

  RET_OK.cint

### End of exported procs
################################################################################

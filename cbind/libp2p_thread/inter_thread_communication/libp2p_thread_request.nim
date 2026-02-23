# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

# Thread Request Dispatcher
#
# This file defines the `LibP2PThreadRequest` type, which acts as a wrapper for all
# request messages handled by the libp2p thread. It supports multiple request types,
# delegating the logic to their respective processors.

import std/json, results
import chronos, chronos/threadsync
import
  ../../[ffi_types, types, alloc],
  ./requests/[
    libp2p_lifecycle_requests, libp2p_peer_manager_requests, libp2p_pubsub_requests,
    libp2p_kademlia_requests, libp2p_stream_requests,
  ],
  ../../../libp2p

type RequestType* {.pure.} = enum
  LIFECYCLE
  PEER_MANAGER
  PUBSUB
  KADEMLIA
  STREAM

type CallbackKind* {.pure.} = enum
  DEFAULT
  PEER_INFO
  PEERS
  GET_VALUE
  GET_PROVIDERS
  RANDOM_RECORDS
  CONNECTED_PEERS
  CONNECTION
  READ

## Central request object passed to the LibP2P thread
type LibP2PThreadRequest* = object
  reqType: RequestType
  reqContent: pointer # pointer to the actual request object
  callbackKind: CallbackKind
  callback: pointer
  userData: pointer

# Shared memory allocation for LibP2PThreadRequest
proc createShared*(
    T: type LibP2PThreadRequest,
    reqType: RequestType,
    reqContent: pointer,
    callback: pointer,
    userData: pointer,
    callbackKind: CallbackKind = CallbackKind.DEFAULT,
): ptr type T =
  var ret = createShared(T)
  ret[].reqType = reqType
  ret[].reqContent = reqContent
  ret[].callbackKind = callbackKind
  ret[].callback = callback
  ret[].userData = userData
  return ret

# Handles responses of type Result[string, string] or Result[void, string]
# Converts the result into a C callback invocation with either RET_OK or RET_ERR
proc handleRes[T](res: Result[T, string], request: ptr LibP2PThreadRequest) =
  ## Handles the Result responses, which can either be Result[string, string] or
  ## Result[void, string].

  defer:
    deallocShared(request)

  let cb = cast[Libp2pCallback](request[].callback)

  if res.isErr():
    foreignThreadGc:
      let msg = "libp2p error: handleRes fireSyncRes error: " & $res.error
      cb(RET_ERR.cint, msg[0].addr, cast[csize_t](len(msg)), request[].userData)
    return

  foreignThreadGc:
    when T is void:
      cb(RET_OK.cint, cast[ptr cchar](""), 0, request[].userData)
    elif T is string:
      let msg = res.get()
      if msg.len == 0:
        cb(RET_OK.cint, cast[ptr cchar](""), 0, request[].userData)
      else:
        cb(RET_OK.cint, addr msg[0], cast[csize_t](len(msg)), request[].userData)
    else:
      raiseAssert "handleRes only supports Result[void, string] or Result[string, string]"
  return

proc handlePeerInfoRes(
    res: Result[ptr Libp2pPeerInfo, string], request: ptr LibP2PThreadRequest
) =
  defer:
    deallocShared(request)

  let cb = cast[PeerInfoCallback](request[].callback)

  let info = res.valueOr:
    foreignThreadGc:
      let msg = $error
      cb(RET_ERR.cint, nil, msg[0].addr, cast[csize_t](len(msg)), request[].userData)
    return

  foreignThreadGc:
    cb(RET_OK.cint, info, nil, 0, request[].userData)

  deallocPeerInfo(info)

proc handleConnectedPeersRes(
    res: Result[ptr ConnectedPeersList, string], request: ptr LibP2PThreadRequest
) =
  defer:
    deallocShared(request)

  let cb = cast[PeersCallback](request[].callback)

  let peers = res.valueOr:
    foreignThreadGc:
      let msg = $error
      cb(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), request[].userData)
    return

  foreignThreadGc:
    cb(RET_OK.cint, peers[].peerIds, peers[].peerIdsLen, nil, 0, request[].userData)

  deallocConnectedPeers(peers)

proc handleFindNodeRes(
    res: Result[ptr FindNodeResult, string], request: ptr LibP2PThreadRequest
) =
  defer:
    deallocShared(request)
  let cb = cast[PeersCallback](request[].callback)

  let peers = res.valueOr:
    foreignThreadGc:
      let msg = $error
      cb(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), request[].userData)
    return

  foreignThreadGc:
    cb(RET_OK.cint, peers[].peerIds, peers[].peerIdsLen, nil, 0, request[].userData)

  deallocFindNodeResult(peers)

proc handleReadRes(
    res: Result[ptr ReadResponse, string], request: ptr LibP2PThreadRequest
) =
  defer:
    deallocShared(request)

  let cb = cast[Libp2pBufferCallback](request[].callback)

  let dataRes = res.valueOr:
    foreignThreadGc:
      let msg = $error
      cb(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), request[].userData)
    return

  foreignThreadGc:
    cb(RET_OK.cint, dataRes[].data, dataRes[].dataLen, nil, 0, request[].userData)

  deallocReadResponse(dataRes)

proc handleGetValueRes(
    res: Result[ptr GetValueResult, string], request: ptr LibP2PThreadRequest
) =
  defer:
    deallocShared(request)

  let cb = cast[Libp2pBufferCallback](request[].callback)

  let valueRes = res.valueOr:
    foreignThreadGc:
      let msg = $error
      cb(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), request[].userData)
    return

  foreignThreadGc:
    cb(RET_OK.cint, valueRes[].value, valueRes[].valueLen, nil, 0, request[].userData)

  deallocGetValueResult(valueRes)

proc handleGetProvidersRes(
    res: Result[ptr ProvidersResult, string], request: ptr LibP2PThreadRequest
) =
  defer:
    deallocShared(request)

  let cb = cast[GetProvidersCallback](request[].callback)

  let providersRes = res.valueOr:
    foreignThreadGc:
      let msg = $error
      cb(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), request[].userData)
    return

  foreignThreadGc:
    cb(
      RET_OK.cint,
      providersRes[].providers,
      providersRes[].providersLen,
      nil,
      0,
      request[].userData,
    )

  deallocProvidersResult(providersRes)

proc handleRandomRecordsRes(
    res: Result[ptr RandomRecordsResult, string], request: ptr LibP2PThreadRequest
) =
  defer:
    deallocShared(request)

  let cb = cast[RandomRecordsCallback](request[].callback)

  let recordsRes = res.valueOr:
    foreignThreadGc:
      let msg = $error
      cb(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), request[].userData)
    return

  foreignThreadGc:
    cb(
      RET_OK.cint,
      recordsRes[].records,
      recordsRes[].recordsLen,
      nil,
      0,
      request[].userData,
    )

  deallocRandomRecordsResult(recordsRes)

proc processLifecycle(
    request: ptr LibP2PThreadRequest, libp2p: ptr LibP2P
) {.async: (raises: [CancelledError]).} =
  let req = cast[ptr LifecycleRequest](request[].reqContent)
  case req[].operation
  of LifecycleMsgType.GET_PUBLIC_KEY:
    handleReadRes(await req.processGetPublicKey(libp2p), request)
  else:
    handleRes(
      await cast[ptr LifecycleRequest](request[].reqContent).process(libp2p), request
    )

proc processPeerManager(
    request: ptr LibP2PThreadRequest, libp2p: ptr LibP2P
) {.async: (raises: [CancelledError]).} =
  case request[].callbackKind
  of CallbackKind.PEER_INFO:
    handlePeerInfoRes(
      await cast[ptr PeerManagementRequest](request[].reqContent).processPeerInfo(
        libp2p
      ),
      request,
    )
  of CallbackKind.PEERS:
    handleConnectedPeersRes(
      await cast[ptr PeerManagementRequest](request[].reqContent).processConnectedPeers(
        libp2p
      ),
      request,
    )
  else:
    handleRes(
      await cast[ptr PeerManagementRequest](request[].reqContent).process(libp2p),
      request,
    )

proc processPubSub(
    request: ptr LibP2PThreadRequest, libp2p: ptr LibP2P
) {.async: (raises: [CancelledError]).} =
  handleRes(
    await cast[ptr PubSubRequest](request[].reqContent).process(libp2p), request
  )

proc processKademlia(
    request: ptr LibP2PThreadRequest, libp2p: ptr LibP2P
) {.async: (raises: [CancelledError]).} =
  let kad = libp2p.kad
  let kadReq = cast[ptr KademliaRequest](request[].reqContent)
  case request[].callbackKind
  of CallbackKind.PEERS:
    handleFindNodeRes(await kadReq.processFindNode(kad), request)
  of CallbackKind.GET_VALUE:
    handleGetValueRes(await kadReq.processGetValue(kad), request)
  of CallbackKind.GET_PROVIDERS:
    handleGetProvidersRes(await kadReq.processGetProviders(kad), request)
  of CallbackKind.RANDOM_RECORDS:
    handleRandomRecordsRes(await kadReq.processRandomRecords(kad), request)
  else:
    handleRes(await kadReq.process(kad), request)

proc handleConnectionRes(
    res: Result[ptr Libp2pStream, string], request: ptr LibP2PThreadRequest
) =
  defer:
    deallocShared(request)

  let cb = cast[ConnectionCallback](request[].callback)

  let conn = res.valueOr:
    foreignThreadGc:
      let msg = $error
      cb(RET_ERR.cint, nil, msg[0].addr, cast[csize_t](len(msg)), request[].userData)
    return

  foreignThreadGc:
    cb(RET_OK.cint, conn, nil, 0, request[].userData)

proc processStream(
    request: ptr LibP2PThreadRequest, libp2p: ptr LibP2P
) {.async: (raises: [CancelledError]).} =
  let req = cast[ptr StreamRequest](request[].reqContent)
  case req[].operation
  of StreamMsgType.DIAL:
    handleConnectionRes(await req.processDial(libp2p), request)
  of StreamMsgType.MIX_DIAL:
    handleConnectionRes(await req.processMixDial(libp2p), request)
  of StreamMsgType.MIX_REGISTER_DEST_READ:
    handleRes(await req.processMixRegisterDestRead(libp2p), request)
  of StreamMsgType.MIX_SET_NODE_INFO:
    handleRes(await req.processMixSetNodeInfo(libp2p), request)
  of StreamMsgType.MIX_NODEPOOL_ADD:
    handleRes(await req.processMixNodePoolAdd(libp2p), request)
  of StreamMsgType.CLOSE, StreamMsgType.CLOSE_WITH_EOF:
    handleRes(await req.processClose(libp2p), request)
  of StreamMsgType.RELEASE:
    handleRes(await req.processRelease(libp2p), request)
  of StreamMsgType.WRITE, StreamMsgType.WRITELP:
    handleRes(await req.processWrite(libp2p), request)
  of StreamMsgType.READEXACTLY, StreamMsgType.READLP:
    handleReadRes(await req.processRead(libp2p), request)

# Dispatcher for processing the request based on its type
# Casts reqContent to the correct request struct and runs its `.process()` logic
proc process*(
    T: type LibP2PThreadRequest, request: ptr LibP2PThreadRequest, libp2p: ptr LibP2P
) {.async: (raises: [CancelledError]).} =
  case request[].reqType
  of RequestType.LIFECYCLE:
    await processLifecycle(request, libp2p)
  of RequestType.PEER_MANAGER:
    await processPeerManager(request, libp2p)
  of RequestType.PUBSUB:
    await processPubSub(request, libp2p)
  of RequestType.KADEMLIA:
    await processKademlia(request, libp2p)
  of RequestType.STREAM:
    await processStream(request, libp2p)

# String representation of the request type
proc `$`*(self: LibP2PThreadRequest): string =
  return $self.reqType

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
  ./requests/
    [libp2p_lifecycle_requests, libp2p_peer_manager_requests, libp2p_pubsub_requests],
  ../../../libp2p

type RequestType* {.pure.} = enum
  LIFECYCLE
  PEER_MANAGER
  PUBSUB

type CallbackKind* {.pure.} = enum
  DEFAULT
  PEER_INFO
  CONNECTED_PEERS

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
proc handleRes(res: Result[string, string], request: ptr LibP2PThreadRequest) =
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
    if res.get() == "":
      request[].callback(RET_OK.cint, cast[ptr cchar](""), 0, request[].userData)
    else:
      var msg: cstring = res.get().cstring
      request[].callback(
        RET_OK.cint, msg[0].addr, cast[csize_t](len(msg)), request[].userData
      )
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

  let cb = cast[ConnectedPeersCallback](request[].callback)

  let peers = res.valueOr:
    foreignThreadGc:
      let msg = $error
      cb(RET_ERR.cint, nil, 0, msg[0].addr, cast[csize_t](len(msg)), request[].userData)
    return

  foreignThreadGc:
    cb(
      RET_OK.cint,
      peers[].peerIds,
      peers[].peerIdsLen,
      nil,
      0,
      request[].userData,
    )

  deallocConnectedPeers(peers)

# Dispatcher for processing the request based on its type
# Casts reqContent to the correct request struct and runs its `.process()` logic
proc process*(
    T: type LibP2PThreadRequest, request: ptr LibP2PThreadRequest, libp2p: ptr LibP2P
) {.async: (raises: [CancelledError]).} =
  case request[].reqType
  of RequestType.LIFECYCLE:
    handleRes(
      await cast[ptr LifecycleRequest](request[].reqContent).process(libp2p), request
    )
  of RequestType.PEER_MANAGER:
    if request[].callbackKind == CallbackKind.PEER_INFO:
      handlePeerInfoRes(
        await cast[ptr PeerManagementRequest](request[].reqContent).processPeerInfo(
          libp2p
        ),
        request,
      )
    elif request[].callbackKind == CallbackKind.CONNECTED_PEERS:
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
  of RequestType.PUBSUB:
    handleRes(
      await cast[ptr PubSubRequest](request[].reqContent).process(libp2p), request
    )

# String representation of the request type
proc `$`*(self: LibP2PThreadRequest): string =
  return $self.reqType

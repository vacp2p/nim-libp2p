# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

import std/[json, sequtils]
import chronos, results
import ../../../[alloc, ffi_types, types]
import ../../../../libp2p

type PeerManagementMsgType* = enum
  CONNECT
  DISCONNECT
  PEER_INFO
  CONNECTED_PEERS

type PeerManagementRequest* = object
  operation: PeerManagementMsgType
  peerId: cstring
  multiaddrs: SharedSeq[cstring]
  timeout: Duration
  direction: Direction

type ConnectedPeersList* = object
  peerIds*: ptr cstring
  peerIdsLen*: csize_t

proc deallocPeerInfo*(info: ptr Libp2pPeerInfo) =
  if info.isNil():
    return

  if not info[].peerId.isNil():
    deallocShared(info[].peerId)

  deallocCStringArray(info[].addrs, info[].addrsLen)

  deallocShared(info)

proc createShared*(
    T: type PeerManagementRequest,
    op: PeerManagementMsgType,
    peerId: cstring = "",
    multiaddrs: ptr cstring = nil,
    multiaddrsLen: csize_t = 0,
    timeout = InfiniteDuration, # not all ops need a timeout
    direction: Direction = Direction.In,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  ret[].multiaddrs = allocSharedSeqFromCArray(multiaddrs, multiaddrsLen.int)
  ret[].timeout = timeout
  ret[].direction = direction
  return ret

proc destroyShared(self: ptr PeerManagementRequest) =
  deallocShared(self[].peerId)
  deallocSharedSeq(self[].multiaddrs)
  deallocShared(self)

proc deallocConnectedPeers*(peers: ptr ConnectedPeersList) =
  if peers.isNil():
    return

  deallocCStringArray(peers[].peerIds, peers[].peerIdsLen)

  deallocShared(peers)

proc process*(
    self: ptr PeerManagementRequest, libp2p: ptr LibP2P
): Future[Result[void, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  case self.operation
  of CONNECT:
    let multiaddresses =
      try:
        self.multiaddrs.toSeq().mapIt(MultiAddress.init($it).tryGet())
      except LPError:
        return err("invalid multiaddress")
    let peerId = PeerId.init($self[].peerId).valueOr:
      return err($error)
    try:
      await libp2p.switch.connect(peerId, multiaddresses).wait(self[].timeout)
    except AsyncTimeoutError:
      return err("dial timeout")
    except DialFailedError as exc:
      return err($exc.msg)
  of DISCONNECT:
    let peerId = PeerId.init($self[].peerId).valueOr:
      return err($error)
    await libp2p.switch.disconnect(peerId)
  else:
    raiseAssert "unsupported operation"

  return ok()

proc processPeerInfo*(
    self: ptr PeerManagementRequest, libp2p: ptr LibP2P
): Future[Result[ptr Libp2pPeerInfo, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  let infoPtr = cast[ptr Libp2pPeerInfo](createShared(Libp2pPeerInfo, 1))
  try:
    infoPtr[].peerId = ($libp2p.switch.peerInfo.peerId).alloc()

    let addrs = libp2p.switch.peerInfo.addrs.mapIt($it)
    infoPtr[].addrsLen = addrs.len.csize_t
    infoPtr[].addrs = allocCStringArrayFromSeq(addrs)
  except LPError as exc:
    deallocPeerInfo(infoPtr)
    return err(exc.msg)

  return ok(infoPtr)

proc processConnectedPeers*(
    self: ptr PeerManagementRequest, libp2p: ptr LibP2P
): Future[Result[ptr ConnectedPeersList, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  let peersPtr = cast[ptr ConnectedPeersList](createShared(ConnectedPeersList, 1))
  let peers = libp2p.switch.connectedPeers(self[].direction)
  peersPtr[].peerIdsLen = peers.len.csize_t

  if peers.len == 0:
    peersPtr[].peerIds = nil
    return ok(peersPtr)

  peersPtr[].peerIds = cast[ptr cstring](allocShared(sizeof(cstring) * peers.len))
  let peersArr = cast[ptr UncheckedArray[cstring]](peersPtr[].peerIds)
  try:
    for i, peer in peers:
      peersArr[i] = ($peer).alloc()
  except LPError as exc:
    deallocConnectedPeers(peersPtr)
    return err(exc.msg)

  return ok(peersPtr)

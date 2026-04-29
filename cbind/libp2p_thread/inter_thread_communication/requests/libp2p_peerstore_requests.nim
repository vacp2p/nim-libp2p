# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

import std/[sequtils, tables]
import chronos, results
import ../../../[alloc, ffi_types, types]
import ../../../../libp2p
import ../../../../libp2p/crypto/crypto
import ./libp2p_peer_manager_requests

type PeerStoreMsgType* = enum
  PS_GET_PEERS
  PS_GET_PEER_INFO
  PS_ADD_PEER
  PS_SET_ADDRESSES
  PS_SET_PROTOCOLS
  PS_DELETE_PEER

type PeerStoreRequest* = object
  operation*: PeerStoreMsgType
  peerId: cstring
  addrs: SharedSeq[cstring]
  protocols: SharedSeq[cstring]

proc createShared*(
    T: type PeerStoreRequest,
    op: PeerStoreMsgType,
    peerId: cstring = "",
    addrs: ptr cstring = nil,
    addrsLen: csize_t = 0,
    protocols: ptr cstring = nil,
    protocolsLen: csize_t = 0,
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  ret[].addrs = allocSharedSeqFromCArray(addrs, addrsLen.int)
  ret[].protocols = allocSharedSeqFromCArray(protocols, protocolsLen.int)
  return ret

proc destroyShared*(self: ptr PeerStoreRequest) =
  deallocShared(self[].peerId)
  deallocSharedSeq(self[].addrs)
  deallocSharedSeq(self[].protocols)
  deallocShared(self)

proc deallocPeerStoreEntry*(e: ptr Libp2pPeerStoreEntry) =
  if e.isNil():
    return
  if not e[].peerId.isNil():
    deallocShared(e[].peerId)
  deallocCStringArray(e[].addrs, e[].addrsLen)
  deallocCStringArray(e[].protocols, e[].protocolsLen)
  if not e[].publicKey.isNil():
    deallocShared(e[].publicKey)
  if not e[].agentVersion.isNil():
    deallocShared(e[].agentVersion)
  if not e[].protoVersion.isNil():
    deallocShared(e[].protoVersion)
  deallocShared(e)

proc process*(
    self: ptr PeerStoreRequest, libp2p: ptr LibP2P
): Future[Result[void, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  let peerId = PeerId.init($self[].peerId).valueOr:
    return err($error)

  let peerStore = libp2p.switch.peerStore

  case self.operation
  of PS_ADD_PEER:
    var addrs = newSeqOfCap[MultiAddress](self[].addrs.len)
    for addr in self[].addrs.toSeq():
      let parsedAddr = MultiAddress.init($addr).valueOr:
        return err($error)
      addrs.add(parsedAddr)
    peerStore[AddressBook].extend(peerId, addrs)
    if self[].protocols.len > 0:
      peerStore[ProtoBook].extend(peerId, self[].protocols.toSeq().mapIt($it))
  of PS_SET_ADDRESSES:
    var addrs = newSeqOfCap[MultiAddress](self[].addrs.len)
    for addr in self[].addrs.toSeq():
      let parsedAddr = MultiAddress.init($addr).valueOr:
        return err($error)
      addrs.add(parsedAddr)
    peerStore[AddressBook][peerId] = addrs
  of PS_SET_PROTOCOLS:
    peerStore[ProtoBook][peerId] = self[].protocols.toSeq().mapIt($it)
  of PS_DELETE_PEER:
    peerStore.del(peerId)
  else:
    raiseAssert "unsupported operation"

  return ok()

proc processGetPeers*(
    self: ptr PeerStoreRequest, libp2p: ptr LibP2P
): Future[Result[ptr ConnectedPeersList, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  let peersPtr = cast[ptr ConnectedPeersList](createShared(ConnectedPeersList, 1))

  var peerIds: seq[string]
  try:
    for peerId in keys(libp2p.switch.peerStore[AddressBook].book):
      peerIds.add($peerId)
  except LPError as exc:
    deallocConnectedPeers(peersPtr)
    return err(exc.msg)

  peersPtr[].peerIdsLen = peerIds.len.csize_t
  if peerIds.len == 0:
    peersPtr[].peerIds = nil
    return ok(peersPtr)

  peersPtr[].peerIds = allocCStringArrayFromSeq(peerIds)
  return ok(peersPtr)

proc processGetPeerInfo*(
    self: ptr PeerStoreRequest, libp2p: ptr LibP2P
): Future[Result[ptr Libp2pPeerStoreEntry, string]] {.async: (raises: []).} =
  defer:
    destroyShared(self)

  let peerId = PeerId.init($self[].peerId).valueOr:
    return err($error)

  let peerStore = libp2p.switch.peerStore
  let entryPtr = cast[ptr Libp2pPeerStoreEntry](createShared(Libp2pPeerStoreEntry, 1))

  try:
    entryPtr[].peerId = ($peerId).alloc()

    let addrs = peerStore[AddressBook][peerId].mapIt($it)
    entryPtr[].addrsLen = addrs.len.csize_t
    entryPtr[].addrs = allocCStringArrayFromSeq(addrs)

    let protos = peerStore[ProtoBook][peerId]
    entryPtr[].protocolsLen = protos.len.csize_t
    entryPtr[].protocols = allocCStringArrayFromSeq(protos)

    if peerStore[KeyBook].contains(peerId):
      let keyBytes = peerStore[KeyBook][peerId].getBytes().valueOr:
        seq[byte].default
      if keyBytes.len > 0:
        entryPtr[].publicKeyLen = keyBytes.len.csize_t
        entryPtr[].publicKey = cast[ptr byte](allocShared(keyBytes.len))
        copyMem(entryPtr[].publicKey, unsafeAddr keyBytes[0], keyBytes.len)

    entryPtr[].agentVersion = peerStore[AgentBook][peerId].alloc()
    entryPtr[].protoVersion = peerStore[ProtoVersionBook][peerId].alloc()
  except LPError as exc:
    deallocPeerStoreEntry(entryPtr)
    return err(exc.msg)

  return ok(entryPtr)

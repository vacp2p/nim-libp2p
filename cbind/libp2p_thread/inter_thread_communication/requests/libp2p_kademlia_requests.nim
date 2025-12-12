# Nim-LibP2P
# Copyright (c) 2023-2025 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import std/[sequtils]
import chronos, results, sets
import ../../../[alloc, ffi_types, types]
import ../../../../libp2p
import ../../../../libp2p/protocols/kademlia
import ./libp2p_peer_manager_requests

type KademliaMsgType* = enum
  FIND_NODE
  PUT_VALUE
  GET_VALUE
  ADD_PROVIDER
  GET_PROVIDERS

type KademliaRequest* = object
  operation: KademliaMsgType
  peerId: cstring
  key: SharedSeq[byte]
  value: SharedSeq[byte]
  cid: cstring

type FindNodeResult* = object
  peerIds*: ptr cstring
  peerIdsLen*: csize_t

type GetValueResult* = object
  value*: ptr byte
  valueLen*: csize_t

type ProvidersResult* = object
  providers*: ptr Libp2pPeerInfo
  providersLen*: csize_t

proc createShared*(
    T: type KademliaRequest,
    op: KademliaMsgType,
    peerId: cstring = "",
    key: ptr byte = nil,
    keyLen: csize_t = 0,
    value: ptr byte = nil,
    valueLen: csize_t = 0,
    cid: cstring = "",
): ptr type T =
  var ret = createShared(T)
  ret[].operation = op
  ret[].peerId = peerId.alloc()
  ret[].key = allocSharedSeqFromCArray(key, keyLen.int)
  ret[].value = allocSharedSeqFromCArray(value, valueLen.int)
  ret[].cid = cid.alloc()
  return ret

proc destroyShared(self: ptr KademliaRequest) =
  deallocShared(self[].peerId)
  deallocSharedSeq(self[].key)
  deallocSharedSeq(self[].value)
  deallocShared(self[].cid)
  deallocShared(self)

proc deallocFindNodeResult*(res: ptr FindNodeResult) =
  if res.isNil():
    return

  if not res[].peerIds.isNil():
    let peersArr = cast[ptr UncheckedArray[cstring]](res[].peerIds)
    for i in 0 ..< int(res[].peerIdsLen):
      if not peersArr[i].isNil():
        deallocShared(peersArr[i])
    deallocShared(peersArr)

  deallocShared(res)

proc deallocGetValueResult*(res: ptr GetValueResult) =
  if res.isNil():
    return

  if not res[].value.isNil():
    deallocShared(res[].value)

  deallocShared(res)

proc deallocProvidersResult*(res: ptr ProvidersResult) =
  if res.isNil():
    return

  if not res[].providers.isNil():
    let providersArr = cast[ptr UncheckedArray[Libp2pPeerInfo]](res[].providers)
    for i in 0 ..< int(res[].providersLen):
      if not providersArr[i].peerId.isNil():
        deallocShared(providersArr[i].peerId)
      if not providersArr[i].addrs.isNil():
        let addrsArr = cast[ptr UncheckedArray[cstring]](providersArr[i].addrs)
        for j in 0 ..< int(providersArr[i].addrsLen):
          if not addrsArr[j].isNil():
            deallocShared(addrsArr[j])
        deallocShared(addrsArr)
    deallocShared(providersArr)

  deallocShared(res)

proc process*(
    self: ptr KademliaRequest, libp2p: ptr LibP2P
): Future[Result[string, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  if libp2p.kad.isNil():
    return err("kad-dht not initialized")

  case self.operation
  of PUT_VALUE:
    let res = await libp2p.kad.putValue(self[].key.toSeq(), self[].value.toSeq())
    if res.isErr():
      return err(res.error)
  of ADD_PROVIDER:
    let cid = Cid.init($self[].cid).valueOr:
      return err($error)
    await libp2p.kad.addProvider(cid)
  else:
    raiseAssert "unsupported path, use specific processor"

  ok("")

proc processFindNode*(
    self: ptr KademliaRequest, libp2p: ptr LibP2P
): Future[Result[ptr FindNodeResult, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  if libp2p.kad.isNil():
    return err("kad-dht not initialized")

  let target = PeerId.init($self[].peerId).valueOr:
    return err($error)

  let peers =
    try:
      await libp2p.kad.findNode(target.toKey())
    except CatchableError as exc:
      return err(exc.msg)

  let resPtr = cast[ptr FindNodeResult](createShared(FindNodeResult, 1))
  resPtr[].peerIdsLen = peers.len.csize_t

  if peers.len == 0:
    resPtr[].peerIds = nil
    return ok(resPtr)

  resPtr[].peerIds = cast[ptr cstring](allocShared(sizeof(cstring) * peers.len))
  let arr = cast[ptr UncheckedArray[cstring]](resPtr[].peerIds)

  try:
    for i, p in peers:
      arr[i] = ($p).alloc()
  except CatchableError as exc:
    deallocFindNodeResult(resPtr)
    return err(exc.msg)

  ok(resPtr)

proc processGetValue*(
    self: ptr KademliaRequest, libp2p: ptr LibP2P
): Future[Result[ptr GetValueResult, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  if libp2p.kad.isNil():
    return err("kad-dht not initialized")

  let res =
    try:
      await libp2p.kad.getValue(self[].key.toSeq())
    except CatchableError as exc:
      return err(exc.msg)

  let entry = res.valueOr:
    return err($res.error)

  let valueLen = entry.value.len
  let resPtr = cast[ptr GetValueResult](createShared(GetValueResult, 1))
  resPtr[].valueLen = valueLen.csize_t

  if valueLen == 0:
    resPtr[].value = nil
    return ok(resPtr)

  resPtr[].value = cast[ptr byte](allocShared(valueLen))
  try:
    copyMem(resPtr[].value, addr entry.value[0], valueLen)
  except CatchableError as exc:
    deallocGetValueResult(resPtr)
    return err(exc.msg)

  ok(resPtr)

proc processGetProviders*(
    self: ptr KademliaRequest, libp2p: ptr LibP2P
): Future[Result[ptr ProvidersResult, string]] {.async: (raises: [CancelledError]).} =
  defer:
    destroyShared(self)

  if libp2p.kad.isNil():
    return err("kad-dht not initialized")

  let cid = Cid.init($self[].cid).valueOr:
    return err($error)

  let providersSet =
    try:
      await libp2p.kad.getProviders(cid.toKey())
    except CatchableError as exc:
      return err(exc.msg)

  let providers = providersSet.toSeq()
  let resPtr = cast[ptr ProvidersResult](createShared(ProvidersResult, 1))
  resPtr[].providersLen = providers.len.csize_t

  if providers.len == 0:
    resPtr[].providers = nil
    return ok(resPtr)

  resPtr[].providers =
    cast[ptr Libp2pPeerInfo](allocShared(sizeof(Libp2pPeerInfo) * providers.len))
  let arr = cast[ptr UncheckedArray[Libp2pPeerInfo]](resPtr[].providers)

  try:
    for i, provider in providers:
      let peerId = PeerId.init(provider.id).valueOr:
        raise newException(ValueError, $error)
      arr[i].peerId = ($peerId).alloc()

      let addrs = provider.addrs.mapIt($it)
      arr[i].addrsLen = addrs.len.csize_t
      if addrs.len == 0:
        arr[i].addrs = nil
      else:
        arr[i].addrs = cast[ptr cstring](allocShared(sizeof(cstring) * addrs.len))
        let addrsArr = cast[ptr UncheckedArray[cstring]](arr[i].addrs)
        for j, addrStr in addrs:
          addrsArr[j] = addrStr.alloc()
  except CatchableError as exc:
    deallocProvidersResult(resPtr)
    return err(exc.msg)

  ok(resPtr)

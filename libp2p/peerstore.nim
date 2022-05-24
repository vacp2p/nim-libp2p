## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

{.push raises: [Defect].}

import
  std/[tables, sets, options, macros],
  ./crypto/crypto,
  ./protocols/identify,
  ./peerid, ./peerinfo,
  ./routing_record,
  ./multiaddress

type
  #################
  # Handler types #
  #################

  PeerBookChangeHandler* = proc(peerId: PeerId) {.gcsafe, raises: [Defect].}
  
  #########
  # Books #
  #########

  # Each book contains a book (map) and event handler(s)
  BasePeerBook = ref object of RootObj
    changeHandlers: seq[PeerBookChangeHandler]
    deletor: PeerBookChangeHandler

  PeerBook*[T] = ref object of BasePeerBook
    book*: Table[PeerId, T]

  SeqPeerBook*[T] = ref object of PeerBook[seq[T]]
  
  AddressBook* = ref object of SeqPeerBook[MultiAddress]
  ProtoBook* = ref object of SeqPeerBook[string]
  KeyBook* = ref object of PeerBook[PublicKey]

  AgentBook* = ref object of PeerBook[string]
  ProtoVersionBook* = ref object of PeerBook[string]
  SPRBook* = ref object of PeerBook[Envelope]
  
  ####################
  # Peer store types #
  ####################

  PeerStore* = ref object
    books: Table[string, BasePeerBook]
    capacity*: int
    toClean*: seq[PeerId]
  
proc new*(T: type PeerStore, capacity = 1000): PeerStore =
  T(capacity: capacity)

#########################
# Generic Peer Book API #
#########################

proc `[]`*[T](peerBook: PeerBook[T],
             peerId: PeerId): T =
  ## Get all the known metadata of a provided peer.
  peerBook.book.getOrDefault(peerId)

proc `[]=`*[T](peerBook: PeerBook[T],
             peerId: PeerId,
             entry: T) =
  ## Set metadata for a given peerId. This will replace any
  ## previously stored metadata.
  
  peerBook.book[peerId] = entry

  # Notify clients
  for handler in peerBook.changeHandlers:
    handler(peerId)

proc del*[T](peerBook: PeerBook[T],
                peerId: PeerId): bool =
  ## Delete the provided peer from the book.
  
  if peerId notin peerBook.book:
    return false
  else:
    peerBook.book.del(peerId)
    # Notify clients
    for handler in peerBook.changeHandlers:
      handler(peerId)
    return true

proc contains*[T](peerBook: PeerBook[T], peerId: PeerId): bool =
  peerId in peerBook.book

proc addHandler*[T](peerBook: PeerBook[T], handler: PeerBookChangeHandler) =
  peerBook.changeHandlers.add(handler)

proc len*[T](peerBook: PeerBook[T]): int = peerBook.book.len

##################  
# Peer Store API #
##################
macro getTypeName(t: type): untyped =
  # Generate unique name in form of Module.Type
  let typ = getTypeImpl(t)[1]
  newLit(repr(typ.owner()) & "." & repr(typ))

proc `[]`*[T](p: PeerStore, typ: type[T]): T =
  let name = getTypeName(T)
  result = T(p.books.getOrDefault(name))
  if result.isNil:
    result = T.new()
    result.deletor = proc(pid: PeerId) =
      # Manual method because generic method
      # don't work
      discard T(p.books.getOrDefault(name)).del(pid)
    p.books[name] = result
  return result

proc del*(peerStore: PeerStore,
             peerId: PeerId) =
  ## Delete the provided peer from every book.
  for _, book in peerStore.books:
    book.deletor(peerId)

proc updatePeerInfo*(
  peerStore: PeerStore,
  info: IdentifyInfo) =

  if info.addrs.len > 0:
    peerStore[AddressBook][info.peerId] = info.addrs

  if info.agentVersion.isSome:
    peerStore[AgentBook][info.peerId] = info.agentVersion.get().string

  if info.protoVersion.isSome:
    peerStore[ProtoVersionBook][info.peerId] = info.protoVersion.get().string

  if info.protos.len > 0:
    peerStore[ProtoBook][info.peerId] = info.protos

  if info.signedPeerRecord.isSome:
    peerStore[SPRBook][info.peerId] = info.signedPeerRecord.get()

  let cleanupPos = peerStore.toClean.find(info.peerId)
  if cleanupPos >= 0:
    peerStore.toClean.delete(cleanupPos)

proc cleanup*(
  peerStore: PeerStore,
  peerId: PeerId) =

  if peerStore.capacity == 0:
    peerStore.del(peerId)
    return
  elif peerStore.capacity < 0:
    #infinite capacity
    return

  peerStore.toClean.add(peerId)
  while peerStore.toClean.len > peerStore.capacity:
    peerStore.del(peerStore.toClean[0])
    peerStore.toClean.delete(0)

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
  std/[tables, sets, sequtils, options],
  ./crypto/crypto,
  ./protocols/identify,
  ./peerid, ./peerinfo,
  ./multiaddress

type
  #################
  # Handler types #
  #################

  PeerBookChangeHandler*[T] = proc(peerId: PeerId)

  AddrChangeHandler* = PeerBookChangeHandler[HashSet[MultiAddress]]
  ProtoChangeHandler* = PeerBookChangeHandler[HashSet[string]]
  KeyChangeHandler* = PeerBookChangeHandler[PublicKey]
  
  #########
  # Books #
  #########

  # Each book contains a book (map) and event handler(s)
  BasePeerBook = ref object of RootObj

  PeerBook*[T] = ref object of BasePeerBook
    book*: Table[PeerId, T]
    changeHandlers: seq[PeerBookChangeHandler[T]]

  SeqPeerBook*[T] = ref object of PeerBook[seq[T]]
  
  AddressBook* = ref object of SeqPeerBook[MultiAddress]
  ProtoBook* = ref object of SeqPeerBook[string]
  KeyBook* = ref object of PeerBook[PublicKey]

  AgentBook* = ref object of PeerBook[string]
  ProtoVersionBook* = ref object of PeerBook[string]
  
  ####################
  # Peer store types #
  ####################

  PeerStore* = ref object
    books: Table[string, BasePeerBook]
  
## Constructs a new PeerStore with metadata of type M
proc new*(T: type PeerStore): PeerStore =
  var p: PeerStore
  new(p)
  return p

#########################
# Generic Peer Book API #
#########################

method del*(peerBook: BasePeerBook, peerId: PeerId): bool {.base.} = discard

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

method del*[T](peerBook: PeerBook[T],
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

proc addHandler*[T](peerBook: PeerBook[T], handler: PeerBookChangeHandler[T]) =
  peerBook.changeHandlers.add(handler)

##################  
# Peer Store API #
##################
proc `[]`*[T](p: PeerStore, typ: type[T]): T =
  let name = $typ
  result = T(p.books.getOrDefault(name))
  if result.isNil:
    result = T.new()
    p.books[name] = result
  return result

proc del*(peerStore: PeerStore,
             peerId: PeerId): bool =
  ## Delete the provided peer from every book.
  for _, book in peerStore.books:
    if book.del(peerId):
      result = true
  return result


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

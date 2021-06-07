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
  ./peerid, ./peerinfo,
  ./multiaddress

type
  #################
  # Handler types #
  #################

  PeerBookChangeHandler*[T] = proc(peerId: PeerID, entry: T)

  AddrChangeHandler* = PeerBookChangeHandler[HashSet[MultiAddress]]
  ProtoChangeHandler* = PeerBookChangeHandler[HashSet[string]]
  KeyChangeHandler* = PeerBookChangeHandler[PublicKey]
  
  #########
  # Books #
  #########

  # Each book contains a book (map) and event handler(s)
  PeerBook*[T] = object of RootObj
    book*: Table[PeerID, T]
    changeHandlers: seq[PeerBookChangeHandler[T]]

  SetPeerBook*[T] = object of PeerBook[HashSet[T]]
  
  AddressBook* = object of SetPeerBook[MultiAddress]
  ProtoBook* = object of SetPeerBook[string]
  KeyBook* = object of PeerBook[PublicKey]
  
  ####################
  # Peer store types #
  ####################

  PeerStore* = ref object
    addressBook*: AddressBook
    protoBook*: ProtoBook
    keyBook*: KeyBook
  
  StoredInfo* = object
    # Collates stored info about a peer
    peerId*: PeerID
    addrs*: HashSet[MultiAddress]
    protos*: HashSet[string]
    publicKey*: PublicKey

## Constructs a new PeerStore with metadata of type M
proc new*(T: type PeerStore): PeerStore =
  var p: PeerStore
  new(p)
  return p

#########################
# Generic Peer Book API #
#########################

proc get*[T](peerBook: PeerBook[T],
             peerId: PeerID): T =
  ## Get all the known metadata of a provided peer.
  
  peerBook.book.getOrDefault(peerId)

proc set*[T](peerBook: var PeerBook[T],
             peerId: PeerID,
             entry: T) =
  ## Set metadata for a given peerId. This will replace any
  ## previously stored metadata.
  
  peerBook.book[peerId] = entry

  # Notify clients
  for handler in peerBook.changeHandlers:
    handler(peerId, peerBook.get(peerId))

proc delete*[T](peerBook: var PeerBook[T],
                peerId: PeerID): bool =
  ## Delete the provided peer from the book.
  
  if not peerBook.book.hasKey(peerId):
    return false
  else:
    peerBook.book.del(peerId)
    return true

################
# Set Book API #
################

proc add*[T](
  peerBook: var SetPeerBook[T],
  peerId: PeerID,
  entry: T) =
  ## Add entry to a given peer. If the peer is not known,
  ## it will be set with the provided entry.
  
  peerBook.book.mgetOrPut(peerId,
                          initHashSet[T]()).incl(entry)
  
  # Notify clients
  for handler in peerBook.changeHandlers:
    handler(peerId, peerBook.get(peerId))

##################  
# Peer Store API #
##################

proc addHandlers*(peerStore: PeerStore,
                  addrChangeHandler: AddrChangeHandler,
                  protoChangeHandler: ProtoChangeHandler,
                  keyChangeHandler: KeyChangeHandler) =
  ## Register event handlers to notify clients of changes in the peer store
  
  peerStore.addressBook.changeHandlers.add(addrChangeHandler)
  peerStore.protoBook.changeHandlers.add(protoChangeHandler)
  peerStore.keyBook.changeHandlers.add(keyChangeHandler)

proc delete*(peerStore: PeerStore,
             peerId: PeerID): bool =
  ## Delete the provided peer from every book.
  
  peerStore.addressBook.delete(peerId) and
  peerStore.protoBook.delete(peerId) and
  peerStore.keyBook.delete(peerId)

proc get*(peerStore: PeerStore,
          peerId: PeerID): StoredInfo =
  ## Get the stored information of a given peer.
  
  StoredInfo(
    peerId: peerId,
    addrs: peerStore.addressBook.get(peerId),
    protos: peerStore.protoBook.get(peerId),
    publicKey: peerStore.keyBook.get(peerId)
  )

proc update*(peerStore: PeerStore, peerInfo: PeerInfo) =
  for address in peerInfo.addrs:
    peerStore.addressBook.add(peerInfo.peerId, address)
  for proto in peerInfo.protocols:
    peerStore.protoBook.add(peerInfo.peerId, proto)
  let pKey = peerInfo.publicKey()
  if pKey.isSome:
    peerStore.keyBook.set(peerInfo.peerId, pKey.get())

proc replace*(peerStore: PeerStore, peerInfo: PeerInfo) =
  discard peerStore.addressBook.delete(peerInfo.peerId)
  discard peerStore.protoBook.delete(peerInfo.peerId)
  discard peerStore.keyBook.delete(peerInfo.peerId)
  peerStore.update(peerInfo)

proc peers*(peerStore: PeerStore): seq[StoredInfo] =
  ## Get all the stored information of every peer.
  
  let allKeys = concat(toSeq(keys(peerStore.addressBook.book)),
                       toSeq(keys(peerStore.protoBook.book)),
                       toSeq(keys(peerStore.keyBook.book))).toHashSet()

  return allKeys.mapIt(peerStore.get(it))

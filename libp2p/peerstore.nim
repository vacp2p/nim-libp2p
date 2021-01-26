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
  std/[tables, sets, sequtils],
  ./crypto/crypto,
  ./peerid,
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
  
  AddressBook* = object of PeerBook[HashSet[MultiAddress]]
  ProtoBook* = object of PeerBook[HashSet[string]]
  KeyBook* = object of PeerBook[PublicKey]
  
  ####################
  # Peer store types #
  ####################

  PeerStore*[T] = ref object of RootObj
    addressBook*: AddressBook
    protoBook*: ProtoBook
    keyBook*: KeyBook
    # The metadataBook serves as an any-purpose PeerBook to collect
    # client-defined peer metadata
    metadataBook*: PeerBook[T]
  
  StoredInfo*[T] = object
    # Collates stored info about a peer
    peerId*: PeerID    
    addrs*: HashSet[MultiAddress]
    protos*: HashSet[string]
    publicKey*: PublicKey
    metadata*: T

## Constructs a new PeerStore with metadata of type M
proc new*(T: type PeerStore, M: typedesc): PeerStore[M] =
  var p: PeerStore[M]
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

####################
# Address Book API #
####################

proc add*(addressBook: var AddressBook,
          peerId: PeerID,
          multiaddr: MultiAddress) = 
  ## Add known multiaddr of a given peer. If the peer is not known, 
  ## it will be set with the provided multiaddr.
  
  addressBook.book.mgetOrPut(peerId,
                             initHashSet[MultiAddress]()).incl(multiaddr)
  
  # Notify clients
  for handler in addressBook.changeHandlers:
    handler(peerId, addressBook.get(peerId))

#####################
# Protocol Book API #
#####################

proc add*(protoBook: var ProtoBook,
          peerId: PeerID,
          protocol: string) = 
  ## Adds known protocol codec for a given peer. If the peer is not known, 
  ## it will be set with the provided protocol.
  
  protoBook.book.mgetOrPut(peerId,
                           initHashSet[string]()).incl(protocol)
  
  # Notify clients
  for handler in protoBook.changeHandlers:
    handler(peerId, protoBook.get(peerId))

##################  
# Peer Store API #
##################

proc addHandlers*[T](peerStore: PeerStore[T],
                     addrChangeHandler: AddrChangeHandler,
                     protoChangeHandler: ProtoChangeHandler,
                     keyChangeHandler: KeyChangeHandler,
                     metadataChangeHandler: PeerBookChangeHandler[T]) =
  ## Register event handlers to notify clients of changes in the peer store
  
  peerStore.addressBook.changeHandlers.add(addrChangeHandler)
  peerStore.protoBook.changeHandlers.add(protoChangeHandler)
  peerStore.keyBook.changeHandlers.add(keyChangeHandler)
  peerStore.metadataBook.changeHandlers.add(metadataChangeHandler)

proc delete*(peerStore: PeerStore,
             peerId: PeerID): bool =
  ## Delete the provided peer from every book.
  
  peerStore.addressBook.delete(peerId) and
  peerStore.protoBook.delete(peerId) and
  peerStore.keyBook.delete(peerId) and
  peerStore.metadataBook.delete(peerId)

proc get*[T](peerStore: PeerStore[T],
             peerId: PeerID): StoredInfo[T] =
  ## Get the stored information of a given peer.
  
  StoredInfo[T](
    peerId: peerId,
    addrs: peerStore.addressBook.get(peerId),
    protos: peerStore.protoBook.get(peerId),
    publicKey: peerStore.keyBook.get(peerId),
    metadata: peerStore.metadataBook.get(peerId)
  )

proc peers*[T](peerStore: PeerStore[T]): seq[StoredInfo[T]] =
  ## Get all the stored information of every peer.
  
  let allKeys = concat(toSeq(keys(peerStore.addressBook.book)),
                       toSeq(keys(peerStore.protoBook.book)),
                       toSeq(keys(peerStore.keyBook.book)),
                       toSeq(keys(peerStore.metadataBook.book))).toHashSet()

  return allKeys.mapIt(peerStore.get(it))

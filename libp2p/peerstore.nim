## Nim-LibP2P
## Copyright (c) 2021 Status Research & Development GmbH
## Licensed under either of
##  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
##  * MIT license ([LICENSE-MIT](LICENSE-MIT))
## at your option.
## This file may not be copied, modified, or distributed except according to
## those terms.

import
  std/[tables, sets, sequtils],
  ./peerid,
  ./multiaddress

type
  ##############################
  # Listener and handler types #
  ##############################
  
  AddrChangeHandler* = proc(peerId: PeerID, multiaddrs: HashSet[MultiAddress])

  EventListener* = object
    # Listener object with client-defined handlers for peer store events
    addrChange*: AddrChangeHandler
    # @TODO add handlers for other event types
  
  #########
  # Books #
  #########

  # Each book contains a book (map) and event handler(s)
  AddressBook* = object
    book*: Table[PeerID, HashSet[MultiAddress]]
    addrChange: AddrChangeHandler
  
  ####################
  # Peer store types #
  ####################

  PeerStore* = ref object of RootObj
    addressBook*: AddressBook
    listeners: ref seq[EventListener]
  
  StoredInfo* = object
    # Collates stored info about a peer
    ## @TODO include data from other stores once added
    peerId*: PeerID
    addrs*: HashSet[MultiAddress]

proc init(T: type AddressBook, addrChange: AddrChangeHandler): AddressBook =
  T(book: initTable[PeerId, HashSet[MultiAddress]](),
    addrChange: addrChange)

proc init*(T: type PeerStore): PeerStore =
  var listeners: ref seq[EventListener]
  new(listeners)

  listeners[] = newSeq[EventListener]()

  proc addrChange(peerId: PeerID, multiaddrs: HashSet[MultiAddress]) =
    # Notify all listeners of change in multiaddr
    for listener in listeners[]:
      listener.addrChange(peerId, multiaddrs)
  
  T(addressBook: AddressBook.init(addrChange),
    listeners: listeners)

####################
# Address Book API #
####################

proc get*(addressBook: AddressBook,
          peerId: PeerID): HashSet[MultiAddress] =
  ## Get the known addresses of a provided peer.
  
  addressBook.book.getOrDefault(peerId,
                                initHashSet[MultiAddress]())

proc add*(addressBook: var AddressBook,
          peerId: PeerID,
          multiaddr: MultiAddress) = 
  ## Add known multiaddr of a given peer. If the peer is not known, 
  ## it will be set with the provided multiaddr.
  
  addressBook.book.mgetOrPut(peerId,
                             initHashSet[MultiAddress]()).incl(multiaddr)
  addressBook.addrChange(peerId, addressBook.get(peerId)) # Notify clients
  
proc delete*(addressBook: var AddressBook,
             peerId: PeerID): bool =
  ## Delete the provided peer from the book.
  
  if not addressBook.book.hasKey(peerId):
    return false
  else:
    addressBook.book.del(peerId)
    return true

proc set*(addressBook: var AddressBook,
          peerId: PeerID,
          addrs: HashSet[MultiAddress]) =
  ## Set known multiaddresses for a given peer. This will replace previously
  ## stored addresses. Replacing stored multiaddresses might
  ## result in losing obtained certified addresses, which is not desirable.
  ## Consider using addressBook.add() as alternative.
  
  addressBook.book[peerId] = addrs
  addressBook.addrChange(peerId, addressBook.get(peerId)) # Notify clients

##################  
# Peer Store API #
##################

proc addListener*(peerStore: PeerStore,
                  listener: EventListener) =
  ## Register event listener to notify clients of changes in the peer store
  
  peerStore.listeners[].add(listener)

proc delete*(peerStore: PeerStore,
             peerId: PeerID): bool =
  ## Delete the provided peer from every book.
  
  peerStore.addressBook.delete(peerId)

proc get*(peerStore: PeerStore,
          peerId: PeerID): StoredInfo =
  ## Get the stored information of a given peer.
  
  StoredInfo(
    peerId: peerId,
    addrs: peerStore.addressBook.get(peerId)
  )

proc peers*(peerStore: PeerStore): seq[StoredInfo] =
  ## Get all the stored information of every peer.
  
  let allKeys = toSeq(keys(peerStore.addressBook.book)) # @TODO concat keys from other books

  return allKeys.mapIt(peerStore.get(it))

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
  ./crypto/crypto,
  ./peerid,
  ./multiaddress

type
  ##############################
  # Listener and handler types #
  ##############################
  
  AddrChangeHandler* = proc(peerId: PeerID, multiaddrs: HashSet[MultiAddress])
  ProtoChangeHandler* = proc(peerId: PeerID, protos: HashSet[string])
  KeyChangeHandler* = proc(peerId: PeerID, publicKey: PublicKey)
  MetadataChangeHandler* = proc(peerId: PeerID, metadata: Table[string, seq[byte]])

  EventListener* = object
    # Listener object with client-defined handlers for peer store events
    addrChange*: AddrChangeHandler
    protoChange*: ProtoChangeHandler
    keyChange*: KeyChangeHandler
    metadataChange*: MetadataChangeHandler
  
  #########
  # Books #
  #########

  # Each book contains a book (map) and event handler(s)
  AddressBook* = object
    book*: Table[PeerID, HashSet[MultiAddress]]
    addrChange: AddrChangeHandler
  
  ProtoBook* = object
    book*: Table[PeerID, HashSet[string]]
    protoChange: ProtoChangeHandler
  
  KeyBook* = object
    book*: Table[PeerID, PublicKey]
    keyChange: KeyChangeHandler
  
  MetadataBook* = object
    book*: Table[PeerID, Table[string, seq[byte]]]
    metadataChange: MetadataChangeHandler
  
  ####################
  # Peer store types #
  ####################

  PeerStore* = ref object of RootObj
    addressBook*: AddressBook
    protoBook*: ProtoBook
    keyBook*: KeyBook
    metadataBook*: MetadataBook
    listeners: seq[EventListener]
  
  StoredInfo* = object
    # Collates stored info about a peer
    peerId*: PeerID
    addrs*: HashSet[MultiAddress]
    protos*: HashSet[string]
    publicKey*: PublicKey
    metadata*: Table[string, seq[byte]]

proc init(T: type AddressBook, addrChange: AddrChangeHandler): AddressBook =
  T(book: initTable[PeerId, HashSet[MultiAddress]](),
    addrChange: addrChange)

proc init(T: type ProtoBook, protoChange: ProtoChangeHandler): ProtoBook =
  T(book: initTable[PeerId, HashSet[string]](),
    protoChange: protoChange)

proc init(T: type KeyBook, keyChange: KeyChangeHandler): KeyBook =
  T(book: initTable[PeerId, PublicKey](),
    keyChange: keyChange)

proc init(T: type MetadataBook, metadataChange: MetadataChangeHandler): MetadataBook =
  T(book: initTable[PeerId, Table[string, seq[byte]]](),
    metadataChange: metadataChange)

proc init*(p: PeerStore) =
  p.listeners = newSeq[EventListener]()

  proc addrChange(peerId: PeerID, multiaddrs: HashSet[MultiAddress]) =
    # Notify all listeners of change in multiaddr
    for listener in p.listeners:
      listener.addrChange(peerId, multiaddrs)
  
  proc protoChange(peerId: PeerID, protos: HashSet[string]) =
    # Notify all listeners of change in proto
    for listener in p.listeners:
      listener.protoChange(peerId, protos)
  
  proc keyChange(peerId: PeerID, publicKey: PublicKey) =
    # Notify all listeners of change in public key
    for listener in p.listeners:
      listener.keyChange(peerId, publicKey)
  
  proc metadataChange(peerId: PeerID, metadata: Table[string, seq[byte]]) =
    # Notify all listeners of change in public key
    for listener in p.listeners:
      listener.metadataChange(peerId, metadata)
  
  p.addressBook = AddressBook.init(addrChange)
  p.protoBook = ProtoBook.init(protoChange)
  p.keyBook = KeyBook.init(keyChange)
  p.metadataBook = MetadataBook.init(metadataChange)

proc init*(T: type PeerStore): PeerStore =
  var p: PeerStore
  new(p)
  p.init()
  return p

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

#####################
# Protocol Book API #
#####################

proc get*(protoBook: ProtoBook,
          peerId: PeerID): HashSet[string] =
  ## Get the known protocols of a provided peer.
  
  protoBook.book.getOrDefault(peerId,
                              initHashSet[string]())

proc add*(protoBook: var ProtoBook,
          peerId: PeerID,
          protocol: string) = 
  ## Adds known protocol codec for a given peer. If the peer is not known, 
  ## it will be set with the provided protocol.
  
  protoBook.book.mgetOrPut(peerId,
                           initHashSet[string]()).incl(protocol)
  protoBook.protoChange(peerId, protoBook.get(peerId)) # Notify clients
  
proc delete*(protoBook: var ProtoBook,
             peerId: PeerID): bool =
  ## Delete the provided peer from the book.
  
  if not protoBook.book.hasKey(peerId):
    return false
  else:
    protoBook.book.del(peerId)
    return true

proc set*(protoBook: var ProtoBook,
          peerId: PeerID,
          protocols: HashSet[string]) =
  ## Set known protocol codecs for a given peer. This will replace previously
  ## stored protocols.
  
  protoBook.book[peerId] = protocols
  protoBook.protoChange(peerId, protoBook.get(peerId)) # Notify clients

################
# Key Book API #
################

proc get*(keyBook: KeyBook,
          peerId: PeerID): PublicKey =
  ## Get the known public key of a provided peer.
  
  keyBook.book.getOrDefault(peerId,
                            PublicKey())
  
proc delete*(keyBook: var KeyBook,
             peerId: PeerID): bool =
  ## Delete the provided peer from the book.
  
  if not keyBook.book.hasKey(peerId):
    return false
  else:
    keyBook.book.del(peerId)
    return true

proc set*(keyBook: var KeyBook,
          peerId: PeerID,
          publicKey: PublicKey) =
  ## Set known public key for a given peer. This will replace any
  ## previously stored keys.
  
  keyBook.book[peerId] = publicKey
  keyBook.keyChange(peerId, keyBook.get(peerId)) # Notify clients

#####################
# Metadata Book API #
#####################

proc get*(metadataBook: MetadataBook,
          peerId: PeerID): Table[string, seq[byte]] =
  ## Get all the known metadata of a provided peer.
  
  metadataBook.book.getOrDefault(peerId,
                                 initTable[string, seq[byte]]())

proc getValue*(metadataBook: MetadataBook,
               peerId: PeerID,
               key: string): seq[byte] =
  ## Get metadata for a provided peer corresponding to a specific key.
  
  metadataBook.book.getOrDefault(peerId,
                                 initTable[string, seq[byte]]())
                   .getOrDefault(key,
                                 newSeq[byte]())

proc set*(metadataBook: var MetadataBook,
          peerId: PeerID,
          metadata: Table[string, seq[byte]]) =
  ## Set metadata for a given peerId. This will replace any
  ## previously stored metadata.
  
  metadataBook.book[peerId] = metadata
  metadataBook.metadataChange(peerId, metadataBook.get(peerId))

proc setValue*(metadataBook: var MetadataBook,
               peerId: PeerID,
               key: string,
               value: seq[byte]) =
  ## Set a metadata key-value pair for a given peerId. This will replace
  ## any metadata previously stored against this key.
  
  metadataBook.book.mgetOrPut(peerId,
                              initTable[string, seq[byte]]())[key] = value
  metadataBook.metadataChange(peerId, metadataBook.get(peerId))

proc delete*(metadataBook: var MetadataBook,
             peerId: PeerID): bool =
  ## Delete the provided peer from the book.
  
  if not metadataBook.book.hasKey(peerId):
    return false
  else:
    metadataBook.book.del(peerId)
    return true

proc deleteValue*(metadataBook: var MetadataBook,
                  peerId: PeerID,
                  key: string): bool =
  ## Delete the metadata for a provided peer corresponding to a specific key.
  
  if not metadataBook.book.hasKey(peerId) or not metadataBook.book[peerId].hasKey(key):
    return false
  else:
    metadataBook.book[peerId].del(key)
    metadataBook.metadataChange(peerId, metadataBook.get(peerId))
    return true    

##################  
# Peer Store API #
##################

proc addListener*(peerStore: PeerStore,
                  listener: EventListener) =
  ## Register event listener to notify clients of changes in the peer store
  
  peerStore.listeners.add(listener)

proc delete*(peerStore: PeerStore,
             peerId: PeerID): bool =
  ## Delete the provided peer from every book.
  
  peerStore.addressBook.delete(peerId) and
  peerStore.protoBook.delete(peerId) and
  peerStore.keyBook.delete(peerId) and
  peerStore.metadataBook.delete(peerId)

proc get*(peerStore: PeerStore,
          peerId: PeerID): StoredInfo =
  ## Get the stored information of a given peer.
  
  StoredInfo(
    peerId: peerId,
    addrs: peerStore.addressBook.get(peerId),
    protos: peerStore.protoBook.get(peerId),
    publicKey: peerStore.keyBook.get(peerId),
    metadata: peerStore.metadataBook.get(peerId)
  )

proc peers*(peerStore: PeerStore): seq[StoredInfo] =
  ## Get all the stored information of every peer.
  
  let allKeys = concat(toSeq(keys(peerStore.addressBook.book)),
                       toSeq(keys(peerStore.protoBook.book)),
                       toSeq(keys(peerStore.keyBook.book)),
                       toSeq(keys(peerStore.metadataBook.book))).toHashSet()

  return allKeys.mapIt(peerStore.get(it))

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
  #################
  # Handler types #
  #################
  
  AddrChangeHandler* = proc(peerId: PeerID, multiaddrs: HashSet[MultiAddress])
  ProtoChangeHandler* = proc(peerId: PeerID, protos: HashSet[string])
  KeyChangeHandler* = proc(peerId: PeerID, publicKey: PublicKey)
  MetadataChangeHandler* = proc(peerId: PeerID, metadata: Table[string, seq[byte]])
  
  #########
  # Books #
  #########

  # Each book contains a book (map) and event handler(s)
  AddressBook* = object
    book*: Table[PeerID, HashSet[MultiAddress]]
    changeHandlers: seq[AddrChangeHandler]
  
  ProtoBook* = object
    book*: Table[PeerID, HashSet[string]]
    changeHandlers: seq[ProtoChangeHandler]
  
  KeyBook* = object
    book*: Table[PeerID, PublicKey]
    changeHandlers: seq[KeyChangeHandler]
  
  MetadataBook* = object
    book*: Table[PeerID, Table[string, seq[byte]]]
    changeHandlers: seq[MetadataChangeHandler]
  
  ####################
  # Peer store types #
  ####################

  PeerStore* = ref object of RootObj
    addressBook*: AddressBook
    protoBook*: ProtoBook
    keyBook*: KeyBook
    metadataBook*: MetadataBook
  
  StoredInfo* = object
    # Collates stored info about a peer
    peerId*: PeerID
    addrs*: HashSet[MultiAddress]
    protos*: HashSet[string]
    publicKey*: PublicKey
    metadata*: Table[string, seq[byte]]

proc init(T: type AddressBook): AddressBook =
  T(book: initTable[PeerId, HashSet[MultiAddress]](),
    changeHandlers: newSeq[AddrChangeHandler]())

proc init(T: type ProtoBook): ProtoBook =
  T(book: initTable[PeerId, HashSet[string]](),
    changeHandlers: newSeq[ProtoChangeHandler]())

proc init(T: type KeyBook): KeyBook =
  T(book: initTable[PeerId, PublicKey](),
    changeHandlers: newSeq[KeyChangeHandler]())

proc init(T: type MetadataBook): MetadataBook =
  T(book: initTable[PeerId, Table[string, seq[byte]]](),
    changeHandlers: newSeq[MetadataChangeHandler]())

proc init*(p: PeerStore) =
  p.addressBook = AddressBook.init()
  p.protoBook = ProtoBook.init()
  p.keyBook = KeyBook.init()
  p.metadataBook = MetadataBook.init()

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
  
  # Notify clients
  for handler in addressBook.changeHandlers:
    handler(peerId, addressBook.get(peerId))
  
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

  # Notify clients
  for handler in addressBook.changeHandlers:
    handler(peerId, addressBook.get(peerId))

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
  
  # Notify clients
  for handler in protoBook.changeHandlers:
    handler(peerId, protoBook.get(peerId))
  
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
  
  # Notify clients
  for handler in protoBook.changeHandlers:
    handler(peerId, protoBook.get(peerId))

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

  # Notify clients
  for handler in keyBook.changeHandlers:
    handler(peerId, keyBook.get(peerId))

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

  # Notify clients
  for handler in metadataBook.changeHandlers:
    handler(peerId, metadataBook.get(peerId))

proc setValue*(metadataBook: var MetadataBook,
               peerId: PeerID,
               key: string,
               value: seq[byte]) =
  ## Set a metadata key-value pair for a given peerId. This will replace
  ## any metadata previously stored against this key.
  
  metadataBook.book.mgetOrPut(peerId,
                              initTable[string, seq[byte]]())[key] = value
  
  # Notify clients
  for handler in metadataBook.changeHandlers:
    handler(peerId, metadataBook.get(peerId))

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
    
    # Notify clients
    for handler in metadataBook.changeHandlers:
      handler(peerId, metadataBook.get(peerId))
    
    return true    

##################  
# Peer Store API #
##################

proc addHandlers*(peerStore: PeerStore,
                  addrChangeHandler: AddrChangeHandler,
                  protoChangeHandler: ProtoChangeHandler,
                  keyChangeHandler: KeyChangeHandler,
                  metadataChangeHandler: MetadataChangeHandler) =
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

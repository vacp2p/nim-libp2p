import
  std/[unittest, tables, sequtils, sets],
  ../libp2p/crypto/crypto,
  ../libp2p/multiaddress,
  ../libp2p/peerid,
  ../libp2p/peerstore,
  ./helpers

suite "PeerStore":
  # Testvars
  let
    # Peer 1
    keyPair1 = KeyPair.random(ECDSA, rng[]).get()
    peerId1 = PeerID.init(keyPair1.secKey).get()
    multiaddrStr1 = "/ip4/127.0.0.1/udp/1234/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
    multiaddr1 = MultiAddress.init(multiaddrStr1).get()
    testcodec1 = "/nim/libp2p/test/0.0.1-beta1"
    metadataKey1 = "key1"
    metadataValue1 = cast[seq[byte]]("value1")
    # Peer 2
    keyPair2 = KeyPair.random(ECDSA, rng[]).get()
    peerId2 = PeerID.init(keyPair2.secKey).get()
    multiaddrStr2 = "/ip4/0.0.0.0/tcp/1234/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
    multiaddr2 = MultiAddress.init(multiaddrStr2).get()
    testcodec2 = "/nim/libp2p/test/0.0.2-beta1"
    metadataKey2 = "key2"
    metadataValue2 = cast[seq[byte]]("value2")
  
  test "PeerStore API":
    # Set up peer store
    var
      peerStore = PeerStore.init()
    
    peerStore.addressBook.add(peerId1, multiaddr1)
    peerStore.addressBook.add(peerId2, multiaddr2)
    peerStore.protoBook.add(peerId1, testcodec1)
    peerStore.protoBook.add(peerId2, testcodec2)
    peerStore.keyBook.set(peerId1, keyPair1.pubKey)
    peerStore.keyBook.set(peerId2, keyPair2.pubKey)
    peerStore.metadataBook.set(peerId1, {metadataKey1: metadataValue1}.toTable)
    peerStore.metadataBook.set(peerId2, {metadataKey2: metadataValue2}.toTable)

    # Test PeerStore::get
    let
      peer1Stored = peerStore.get(peerId1)
      peer2Stored = peerStore.get(peerId2)
    check:
      peer1Stored.peerId == peerId1
      peer1Stored.addrs == toHashSet([multiaddr1])
      peer1Stored.protos == toHashSet([testcodec1])
      peer1Stored.publicKey == keyPair1.pubkey
      peer1Stored.metadata == {metadataKey1: metadataValue1}.toTable
      peer2Stored.peerId == peerId2
      peer2Stored.addrs == toHashSet([multiaddr2])
      peer2Stored.protos == toHashSet([testcodec2])
      peer2Stored.publicKey == keyPair2.pubkey
      peer2Stored.metadata == {metadataKey2: metadataValue2}.toTable
    
    # Test PeerStore::peers
    let peers = peerStore.peers()
    check:
      peers.len == 2
      peers.anyIt(it.peerId == peerId1 and
                  it.addrs == toHashSet([multiaddr1]) and
                  it.protos == toHashSet([testcodec1]) and
                  it.publicKey == keyPair1.pubkey and
                  it.metadata == {metadataKey1: metadataValue1}.toTable)
      peers.anyIt(it.peerId == peerId2 and
                  it.addrs == toHashSet([multiaddr2]) and
                  it.protos == toHashSet([testcodec2]) and
                  it.publicKey == keyPair2.pubkey and
                  it.metadata == {metadataKey2: metadataValue2}.toTable)

    # Test PeerStore::delete
    check:
      # Delete existing peerId
      peerStore.delete(peerId1) == true
      peerStore.peers().anyIt(it.peerId == peerId1) == false

      # Now try and delete it again
      peerStore.delete(peerId1) == false
  
  test "PeerStore listeners":
    # Set up peer store with listener
    var
      peerStore = PeerStore.init()
      addrChanged = false
      protoChanged = false
      keyChanged = false
      metadataChanged = false
    
    proc addrChange(peerId: PeerID, addrs: HashSet[MultiAddress]) =
      addrChanged = true
    
    proc protoChange(peerId: PeerID, protos: HashSet[string]) =
      protoChanged = true
    
    proc keyChange(peerId: PeerID, publicKey: PublicKey) =
      keyChanged = true
    
    proc metadataChange(peerId: PeerID, metadata: Table[string, seq[byte]]) =
      metadataChanged = true

    peerStore.addHandlers(addrChangeHandler = addrChange,
                          protoChangeHandler = protoChange,
                          keyChangeHandler = keyChange,
                          metadataChangeHandler = metadataChange)

    # Test listener triggered on adding multiaddr
    peerStore.addressBook.add(peerId1, multiaddr1)
    check:
      addrChanged == true
    
    # Test listener triggered on setting addresses
    addrChanged = false
    peerStore.addressBook.set(peerId2,
                              toHashSet([multiaddr1, multiaddr2]))
    check:
      addrChanged == true
  
    # Test listener triggered on adding proto
    peerStore.protoBook.add(peerId1, testcodec1)
    check:
      protoChanged == true
    
    # Test listener triggered on setting protos
    protoChanged = false
    peerStore.protoBook.set(peerId2,
                            toHashSet([testcodec1, testcodec2]))
    check:
      protoChanged == true
    
    # Test listener triggered on setting public key
    peerStore.keyBook.set(peerId1,
                          keyPair1.pubkey)
    check:
      keyChanged == true
    
    # Test listener triggered on changing public key
    keyChanged = false
    peerStore.keyBook.set(peerId1,
                          keyPair2.pubkey)
    check:
      keyChanged == true
    
    # Test listener triggered on setting metadata value
    peerStore.metadataBook.setValue(peerId1,
                                    metadataKey1,
                                    metadataValue1)
    check:
      metadataChanged == true
    
    # Test listener triggered on setting metadata
    metadataChanged = false
    peerStore.metadataBook.set(peerId1,
                               {metadataKey1: metadataValue1, metadataKey2: metadataValue2}.toTable)
    check:
      metadataChanged == true
    
    # Test listener triggered on deleting metadata value
    metadataChanged = false
    check:
      peerStore.metadataBook.deleteValue(peerId1,
                                         metadataKey1) == true
      metadataChanged == true

  test "AddressBook API":
    # Set up address book
    var
      addressBook = PeerStore.init().addressBook
    
    # Test AddressBook::add
    addressBook.add(peerId1, multiaddr1)
    
    check:
      toSeq(keys(addressBook.book))[0] == peerId1
      toSeq(values(addressBook.book))[0] == toHashSet([multiaddr1])
    
    # Test AddressBook::get
    check:
      addressBook.get(peerId1) == toHashSet([multiaddr1])
    
    # Test AddressBook::delete
    check:
      # Try to delete peerId that doesn't exist
      addressBook.delete(peerId2) == false

      # Delete existing peerId
      addressBook.book.len == 1 # sanity
      addressBook.delete(peerId1) == true
      addressBook.book.len == 0
    
    # Test AddressBook::set
    # Set peerId2 with multiple multiaddrs
    addressBook.set(peerId2,
                toHashSet([multiaddr1, multiaddr2]))
    check:
      toSeq(keys(addressBook.book))[0] == peerId2
      toSeq(values(addressBook.book))[0] == toHashSet([multiaddr1, multiaddr2])
  
  test "ProtoBook API":
    # Set up protocol book
    var
      protoBook = PeerStore.init().protoBook
    
    # Test ProtoBook::add
    protoBook.add(peerId1, testcodec1)
    
    check:
      toSeq(keys(protoBook.book))[0] == peerId1
      toSeq(values(protoBook.book))[0] == toHashSet([testcodec1])
    
    # Test ProtoBook::get
    check:
      protoBook.get(peerId1) == toHashSet([testcodec1])
    
    # Test ProtoBook::delete
    check:
      # Try to delete peerId that doesn't exist
      protoBook.delete(peerId2) == false

      # Delete existing peerId
      protoBook.book.len == 1 # sanity
      protoBook.delete(peerId1) == true
      protoBook.book.len == 0
    
    # Test ProtoBook::set
    # Set peerId2 with multiple protocols
    protoBook.set(peerId2,
                  toHashSet([testcodec1, testcodec2]))
    check:
      toSeq(keys(protoBook.book))[0] == peerId2
      toSeq(values(protoBook.book))[0] == toHashSet([testcodec1, testcodec2])

  test "KeyBook API":
    # Set up key book
    var
      keyBook = PeerStore.init().keyBook
    
    # Test KeyBook::set
    keyBook.set(peerId1,
                keyPair1.pubkey)
    check:
      toSeq(keys(keyBook.book))[0] == peerId1
      toSeq(values(keyBook.book))[0] == keyPair1.pubkey
    
    # Test KeyBook::get
    check:
      keyBook.get(peerId1) == keyPair1.pubkey
    
    # Test KeyBook::delete
    check:
      # Try to delete peerId that doesn't exist
      keyBook.delete(peerId2) == false

      # Delete existing peerId
      keyBook.book.len == 1 # sanity
      keyBook.delete(peerId1) == true
      keyBook.book.len == 0

  test "MetadataBook API":
    # Set up metadata book
    var
      metadataBook = PeerStore.init().metadataBook
    
    # Test MetadataBook::setValue
    metadataBook.setValue(peerId1, metadataKey1, metadataValue1)
    
    check:
      toSeq(keys(metadataBook.book))[0] == peerId1
      toSeq(values(metadataBook.book))[0] == {metadataKey1: metadataValue1}.toTable
    
    # Test MetadataBook::getValue
    check:
      metadataBook.getValue(peerId1, metadataKey1) == metadataValue1
    
    # Test MetadataBook::deleteValue
    check:
      # Try to delete key-value pair that does not exist
      metadataBook.deleteValue(peerId1, metadataKey2) == false

      # Delete existing key-value pair
      metadataBook.book[peerId1].len == 1 # sanity
      metadataBook.deleteValue(peerId1, metadataKey1) == true
      metadataBook.book[peerId1].len == 0

    # Test MetadataBook::set
    # Set peerId1 with multiple metadata key-value pairs
    metadataBook.set(peerId1,
                     {metadataKey1: metadataValue1, metadataKey2: metadataValue2}.toTable)
    check:
      toSeq(keys(metadataBook.book))[0] == peerId1
      toSeq(values(metadataBook.book))[0] == {metadataKey1: metadataValue1, metadataKey2: metadataValue2}.toTable
    
    # Test MetadataBook::get
    check:
      metadataBook.get(peerId1) == {metadataKey1: metadataValue1, metadataKey2: metadataValue2}.toTable
    
    # Test MetadataBook::delete
    check:
      # Try to delete peerId entry that does not exist
      metadataBook.delete(peerId2) == false

      # Delete existing peerId entry
      metadataBook.book.len == 1 # sanity
      metadataBook.delete(peerId1) == true
      metadataBook.book.len == 0

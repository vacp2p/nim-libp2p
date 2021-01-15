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
    seckey1 = PrivateKey.random(ECDSA, rng[]).get()
    peerId1 = PeerID.init(seckey1).get()
    multiaddrStr1 = "/ip4/127.0.0.1/udp/1234/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
    multiaddr1 = MultiAddress.init(multiaddrStr1).get()
    # Peer 2
    seckey2 = PrivateKey.random(ECDSA, rng[]).get()
    peerId2 = PeerID.init(seckey2).get()
    multiaddrStr2 = "/ip4/0.0.0.0/tcp/1234/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
    multiaddr2 = MultiAddress.init(multiaddrStr2).get()
  
  test "PeerStore API":
    # Set up peer store
    var
      peerStore = PeerStore.init()
    
    peerStore.addressBook.add(peerId1, multiaddr1)
    peerStore.addressBook.add(peerId2, multiaddr2)

    # Test PeerStore::get
    let
      peer1Stored = peerStore.get(peerId1)
      peer2Stored = peerStore.get(peerId2)
    check:
      peer1Stored.peerId == peerId1
      peer1Stored.addrs == toHashSet([multiaddr1])
      peer2Stored.peerId == peerId2
      peer2Stored.addrs == toHashSet([multiaddr2])
    
    # Test PeerStore::peers
    let peers = peerStore.peers()
    check:
      peers.len == 2
      peers.anyIt(it.peerId == peerId1 and it.addrs == toHashSet([multiaddr1]))
      peers.anyIt(it.peerId == peerId2 and it.addrs == toHashSet([multiaddr2]))
    
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
    
    proc addrChange(peerId: PeerID, addrs: HashSet[MultiAddress]) =
      addrChanged = true
    
    let listener = EventListener(addrChange: addrChange)

    peerStore.addListener(listener)

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

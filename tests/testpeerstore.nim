import
  unittest2,
  std/[tables, sequtils, sets],
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
    peerId1 = PeerId.init(keyPair1.seckey).get()
    multiaddrStr1 = "/ip4/127.0.0.1/udp/1234/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
    multiaddr1 = MultiAddress.init(multiaddrStr1).get()
    testcodec1 = "/nim/libp2p/test/0.0.1-beta1"
    # Peer 2
    keyPair2 = KeyPair.random(ECDSA, rng[]).get()
    peerId2 = PeerId.init(keyPair2.seckey).get()
    multiaddrStr2 = "/ip4/0.0.0.0/tcp/1234/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
    multiaddr2 = MultiAddress.init(multiaddrStr2).get()
    testcodec2 = "/nim/libp2p/test/0.0.2-beta1"

  test "PeerStore API":
    # Set up peer store
    var
      peerStore = PeerStore.new()

    peerStore.addressBook.add(peerId1, multiaddr1)
    peerStore.addressBook.add(peerId2, multiaddr2)
    peerStore.protoBook.add(peerId1, testcodec1)
    peerStore.protoBook.add(peerId2, testcodec2)
    peerStore.keyBook.set(peerId1, keyPair1.pubkey)
    peerStore.keyBook.set(peerId2, keyPair2.pubkey)

    # Test PeerStore::delete
    check:
      # Delete existing peerId
      peerStore.delete(peerId1) == true
      peerId1 notin peerStore.addressBook

      # Now try and delete it again
      peerStore.delete(peerId1) == false

  test "PeerStore listeners":
    # Set up peer store with listener
    var
      peerStore = PeerStore.new()
      addrChanged = false
      protoChanged = false
      keyChanged = false

    proc addrChange(peerId: PeerId, addrs: HashSet[MultiAddress]) =
      addrChanged = true

    proc protoChange(peerId: PeerId, protos: HashSet[string]) =
      protoChanged = true

    proc keyChange(peerId: PeerId, publicKey: PublicKey) =
      keyChanged = true

    peerStore.addHandlers(addrChangeHandler = addrChange,
                          protoChangeHandler = protoChange,
                          keyChangeHandler = keyChange)

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

  test "AddressBook API":
    # Set up address book
    var
      addressBook = PeerStore.new().addressBook

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
      protoBook = PeerStore.new().protoBook

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
      keyBook = PeerStore.new().keyBook

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

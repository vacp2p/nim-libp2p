{.used.}

# Nim-Libp2p
# Copyright (c) 2023 Status Research & Development GmbH
# Licensed under either of
#  * Apache License, version 2.0, ([LICENSE-APACHE](LICENSE-APACHE))
#  * MIT license ([LICENSE-MIT](LICENSE-MIT))
# at your option.
# This file may not be copied, modified, or distributed except according to
# those terms.

import
  unittest2,
  std/[tables, sequtils],
  ../libp2p/crypto/crypto,
  ../libp2p/multiaddress,
  ../libp2p/peerid,
  ../libp2p/peerstore,
  ./helpers

suite "PeerStore":
  # Testvars
  let
    # Peer 1
    keyPair1 = KeyPair.random(ECDSA, rng).get()
    peerId1 = PeerId.init(keyPair1.seckey).get()
    multiaddrStr1 = "/ip4/127.0.0.1/udp/1234/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
    multiaddr1 = MultiAddress.init(multiaddrStr1).get()
    testcodec1 = "/nim/libp2p/test/0.0.1-beta1"
    # Peer 2
    keyPair2 = KeyPair.random(ECDSA, rng).get()
    peerId2 = PeerId.init(keyPair2.seckey).get()
    multiaddrStr2 = "/ip4/0.0.0.0/tcp/1234/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
    multiaddr2 = MultiAddress.init(multiaddrStr2).get()
    testcodec2 = "/nim/libp2p/test/0.0.2-beta1"

  test "PeerStore API":
    # Set up peer store
    var
      peerStore = PeerStore.new()

    peerStore[AddressBook][peerId1] = @[multiaddr1]
    peerStore[AddressBook][peerId2] = @[multiaddr2]
    peerStore[ProtoBook][peerId1] = @[testcodec1]
    peerStore[ProtoBook][peerId2] = @[testcodec2]
    peerStore[KeyBook][peerId1] = keyPair1.pubkey
    peerStore[KeyBook][peerId2] = keyPair2.pubkey

    # Test PeerStore::del
    # Delete existing peerId
    peerStore.del(peerId1)
    check peerId1 notin peerStore[AddressBook]
    # Now try and del it again
    peerStore.del(peerId1)


  test "PeerStore listeners":
    # Set up peer store with listener
    var
      peerStore = PeerStore.new()
      addrChanged = false

    proc addrChange(peerId: PeerId) {.gcsafe.} =
      addrChanged = true

    peerStore[AddressBook].addHandler(addrChange)

    # Test listener triggered on adding multiaddr
    peerStore[AddressBook][peerId1] = @[multiaddr1]
    check: addrChanged == true

    addrChanged = false
    check:
      peerStore[AddressBook].del(peerId1) == true
      addrChanged == true

  test "PeerBook API":
    # Set up address book
    var addressBook = PeerStore.new()[AddressBook]

    # Test AddressBook::add
    addressBook[peerId1] = @[multiaddr1]

    check:
      toSeq(keys(addressBook.book))[0] == peerId1
      toSeq(values(addressBook.book))[0] == @[multiaddr1]

    # Test AddressBook::get
    check:
      addressBook[peerId1] == @[multiaddr1]

    # Test AddressBook::del
    check:
      # Try to del peerId that doesn't exist
      addressBook.del(peerId2) == false

      # Delete existing peerId
      addressBook.book.len == 1 # sanity
      addressBook.del(peerId1) == true
      addressBook.book.len == 0

    # Test AddressBook::set
    # Set peerId2 with multiple multiaddrs
    addressBook[peerId2] = @[multiaddr1, multiaddr2]
    check:
      toSeq(keys(addressBook.book))[0] == peerId2
      toSeq(values(addressBook.book))[0] == @[multiaddr1, multiaddr2]

  test "Pruner - no capacity":
    let peerStore = PeerStore.new(nil, capacity = 0)
    peerStore[AgentBook][peerId1] = "gds"

    peerStore.cleanup(peerId1)

    check peerId1 notin peerStore[AgentBook]

  test "Pruner - FIFO":
    let peerStore = PeerStore.new(nil, capacity = 1)
    peerStore[AgentBook][peerId1] = "gds"
    peerStore[AgentBook][peerId2] = "gds"
    peerStore.cleanup(peerId2)
    peerStore.cleanup(peerId1)
    check:
      peerId1 in peerStore[AgentBook]
      peerId2 notin peerStore[AgentBook]

  test "Pruner - regular capacity":
    var peerStore = PeerStore.new(nil, capacity = 20)

    for i in 0..<30:
      let randomPeerId = PeerId.init(KeyPair.random(ECDSA, rng).get().pubkey).get()
      peerStore[AgentBook][randomPeerId] = "gds"
      peerStore.cleanup(randomPeerId)

    check peerStore[AgentBook].len == 20

  test "Pruner - infinite capacity":
    var peerStore = PeerStore.new(nil, capacity = -1)

    for i in 0..<30:
      let randomPeerId = PeerId.init(KeyPair.random(ECDSA, rng).get().pubkey).get()
      peerStore[AgentBook][randomPeerId] = "gds"
      peerStore.cleanup(randomPeerId)

    check peerStore[AgentBook].len == 30

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import std/[tables, sequtils]
import ../../libp2p/[crypto/crypto, multiaddress, peerid, peerstore]
import ../tools/[unittest, crypto]

suite "PeerStore":
  # Testvars
  let
    # Peer 1
    keyPair1 = KeyPair.random(ECDSA, rng()).get()
    peerId1 = PeerId.init(keyPair1.seckey).get()
    multiaddrStr1 =
      "/ip4/127.0.0.1/udp/1234/p2p/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
    multiaddr1 = MultiAddress.init(multiaddrStr1).get()
    testcodec1 = "/nim/libp2p/test/0.0.1-beta1"
    # Peer 2
    keyPair2 = KeyPair.random(ECDSA, rng()).get()
    peerId2 = PeerId.init(keyPair2.seckey).get()
    multiaddrStr2 =
      "/ip4/0.0.0.0/tcp/1234/ipfs/QmcgpsyWgH8Y8ajJz1Cu72KnS5uo2Aa2LpzU7kinSupNKC"
    multiaddr2 = MultiAddress.init(multiaddrStr2).get()
    testcodec2 = "/nim/libp2p/test/0.0.2-beta1"

  test "PeerStore API":
    # Set up peer store
    var peerStore = PeerStore.new(nil)

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
      peerStore = PeerStore.new(nil)
      addrChanged = false

    proc addrChange(peerId: PeerId) {.gcsafe.} =
      addrChanged = true

    peerStore[AddressBook].addHandler(addrChange)

    # Test listener triggered on adding multiaddr
    peerStore[AddressBook][peerId1] = @[multiaddr1]
    check:
      addrChanged == true

    addrChanged = false
    check:
      peerStore[AddressBook].del(peerId1) == true
      addrChanged == true

  test "PeerBook API":
    # Set up address book
    var addressBook = PeerStore.new(nil)[AddressBook]

    # Test AddressBook::add
    addressBook[peerId1] = @[multiaddr1]

    check:
      toSeq(keys(addressBook.book))[0] == peerId1
      addressBook[peerId1] == @[multiaddr1]

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
      addressBook[peerId2] == @[multiaddr1, multiaddr2]

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

    for i in 0 ..< 30:
      let randomPeerId = PeerId.init(KeyPair.random(ECDSA, rng()).get().pubkey).get()
      peerStore[AgentBook][randomPeerId] = "gds"
      peerStore.cleanup(randomPeerId)

    check peerStore[AgentBook].len == 20

  test "Pruner - infinite capacity":
    var peerStore = PeerStore.new(nil, capacity = -1)

    for i in 0 ..< 30:
      let randomPeerId = PeerId.init(KeyPair.random(ECDSA, rng()).get().pubkey).get()
      peerStore[AgentBook][randomPeerId] = "gds"
      peerStore.cleanup(randomPeerId)

    check peerStore[AgentBook].len == 30

suite "AddressBook TTL / confidence":
  let
    keyPair1 = KeyPair.random(ECDSA, rng()).get()
    peerId1 = PeerId.init(keyPair1.seckey).get()
    keyPair2 = KeyPair.random(ECDSA, rng()).get()
    peerId2 = PeerId.init(keyPair2.seckey).get()
    addr1 = MultiAddress.init("/ip4/1.2.3.4/tcp/1234").get()
    addr2 = MultiAddress.init("/ip4/5.6.7.8/tcp/5678").get()

  proc makeBook(low, medium, high: Duration): AddressBook =
    let b = AddressBook.new()
    b.ttls = AddressConfidenceTtls(low: low, medium: medium, high: high)
    b

  test "isExpired - Low expires after low TTL":
    let ttls = AddressConfidenceTtls(low: 1.seconds, medium: 1.hours, high: 24.hours)
    let entry = AddressEntry(
      address: addr1,
      confidence: AddressConfidence.Low,
      lastUpdated: Moment.now() - 2.seconds,
    )
    check entry.isExpired(ttls) == true

  test "isExpired - Low not expired within TTL":
    let ttls = AddressConfidenceTtls(low: 1.hours, medium: 1.hours, high: 24.hours)
    let entry = AddressEntry(
      address: addr1, confidence: AddressConfidence.Low, lastUpdated: Moment.now()
    )
    check entry.isExpired(ttls) == false

  test "isExpired - Medium expires after medium TTL":
    let ttls = AddressConfidenceTtls(low: 1.hours, medium: 1.seconds, high: 24.hours)
    let entry = AddressEntry(
      address: addr1,
      confidence: AddressConfidence.Medium,
      lastUpdated: Moment.now() - 2.seconds,
    )
    check entry.isExpired(ttls) == true

  test "isExpired - High expires after high TTL":
    let ttls = AddressConfidenceTtls(low: 1.hours, medium: 1.hours, high: 1.seconds)
    let entry = AddressEntry(
      address: addr1,
      confidence: AddressConfidence.High,
      lastUpdated: Moment.now() - 2.seconds,
    )
    check entry.isExpired(ttls) == true

  test "isExpired - Infinite never expires":
    let ttls = AddressConfidenceTtls(low: 0.seconds, medium: 0.seconds, high: 0.seconds)
    let entry = AddressEntry(
      address: addr1,
      confidence: AddressConfidence.Infinite,
      lastUpdated: Moment.now() - 365.days,
    )
    check entry.isExpired(ttls) == false

  test "pruneExpired removes only expired entries, keeps live ones":
    let book = makeBook(1.seconds, 1.hours, 24.hours)
    book.set(peerId1, @[addr1], AddressConfidence.Low)
    book.set(peerId1, @[addr2], AddressConfidence.Medium)
    # Back-date the Low entry so it's expired
    book.book[peerId1][0].lastUpdated = Moment.now() - 2.seconds
    book.pruneExpired()
    let remaining = book[peerId1]
    check:
      addr1 notin remaining
      addr2 in remaining

  test "pruneExpired removes peer from AddressBook when all addresses expire":
    let book = makeBook(1.seconds, 1.seconds, 1.seconds)
    book.set(peerId1, @[addr1], AddressConfidence.Low)
    book.book[peerId1][0].lastUpdated = Moment.now() - 2.seconds
    book.pruneExpired()
    check peerId1 notin book

  test "pruneExpired leaves other PeerStore books intact":
    let peerStore = PeerStore.new(nil)
    peerStore[AgentBook][peerId1] = "go-libp2p"
    peerStore[KeyBook][peerId1] = keyPair1.pubkey
    peerStore[AddressBook].set(peerId1, @[addr1], AddressConfidence.Low)
    peerStore[AddressBook].book[peerId1][0].lastUpdated = Moment.now() - 2.seconds
    peerStore[AddressBook].pruneExpired()
    check:
      peerId1 notin peerStore[AddressBook]
      peerStore[AgentBook][peerId1] == "go-libp2p"
      peerId1 in peerStore[KeyBook]

  test "markConnected upgrades existing address to High confidence":
    let book = makeBook(1.hours, 1.hours, 24.hours)
    book.set(peerId1, @[addr1], AddressConfidence.Low)
    book.markConnected(peerId1, addr1)
    check book.entries(peerId1)[0].confidence == AddressConfidence.High

  test "markConnected adds address when not already present":
    let book = makeBook(1.hours, 1.hours, 24.hours)
    book.markConnected(peerId1, addr1)
    let entries = book.entries(peerId1)
    check:
      entries.len == 1
      entries[0].address == addr1
      entries[0].confidence == AddressConfidence.High

  test "markConnected refreshes lastUpdated so address is not expired":
    let book = makeBook(1.seconds, 1.hours, 24.hours)
    book.set(peerId1, @[addr1], AddressConfidence.Low)
    book.book[peerId1][0].lastUpdated = Moment.now() - 2.seconds
    # Entry is expired as Low; markConnected should refresh it
    book.markConnected(peerId1, addr1)
    check not book.entries(peerId1)[0].isExpired(book.ttls)

  test "set does not downgrade High confidence to Low":
    let book = makeBook(1.hours, 1.hours, 24.hours)
    book.set(peerId1, @[addr1], AddressConfidence.High)
    book.set(peerId1, @[addr1], AddressConfidence.Low)
    check book.entries(peerId1)[0].confidence == AddressConfidence.High

  test "extend does not downgrade existing confidence":
    let book = makeBook(1.hours, 1.hours, 24.hours)
    book.set(peerId1, @[addr1], AddressConfidence.High)
    book.extend(peerId1, @[addr1], AddressConfidence.Low)
    check book.entries(peerId1)[0].confidence == AddressConfidence.High

# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH

{.used.}

import results
import ../../../libp2p/[crypto/crypto, crypto/secp, multiaddress, peerid, peerstore]
import ../../../libp2p/protocols/mix/[mix_node, pool]
import ../../tools/unittest

suite "MixNodePool Tests":
  var
    peerStore {.threadvar.}: PeerStore
    pool {.threadvar.}: MixNodePool
    mixNodes {.threadvar.}: MixNodes

  setup:
    peerStore = PeerStore.new()
    pool = MixNodePool.new(peerStore)
    mixNodes = initializeMixNodes(5).expect("could not generate mix nodes")

  teardown:
    deleteNodeInfoFolder()
    deletePubInfoFolder()

  test "new creates empty pool":
    check pool.len == 0

  test "add stores mix node info":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")

    pool.add(pubInfo)

    check:
      pool.len == 1
      pool.get(pubInfo.peerId).isSome
      pool.get(pubInfo.peerId).get() == pubInfo

  test "add stores all required data in peerStore":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")

    pool.add(pubInfo)

    check:
      peerStore[MixPubKeyBook][pubInfo.peerId] == pubInfo.mixPubKey
      peerStore[AddressBook][pubInfo.peerId] == @[pubInfo.multiAddr]
      peerStore[KeyBook][pubInfo.peerId].scheme == Secp256k1
      peerStore[KeyBook][pubInfo.peerId].skkey == pubInfo.libp2pPubKey

  test "remove deletes from pool":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")

    pool.add(pubInfo)
    check pool.len == 1

    let removed = pool.remove(pubInfo.peerId)

    check:
      removed == true
      pool.len == 0
      pool.get(pubInfo.peerId).isNone

  test "remove returns false for non-existent peer":
    let peerId = PeerId.random().expect("could not generate peerId")
    check pool.remove(peerId) == false

  test "get returns none for non-existent peer":
    let peerId = PeerId.random().expect("could not generate peerId")
    check pool.get(peerId).isNone

  test "get returns none when address is missing":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")

    # Manually add only the mix key, not the address
    peerStore[MixPubKeyBook][pubInfo.peerId] = pubInfo.mixPubKey

    check pool.get(pubInfo.peerId).isNone

  test "get returns none when key scheme is not Secp256k1":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")

    # Manually add with wrong key scheme
    peerStore[MixPubKeyBook][pubInfo.peerId] = pubInfo.mixPubKey
    peerStore[AddressBook][pubInfo.peerId] = @[pubInfo.multiAddr]
    # KeyBook is not set, so scheme defaults to something other than Secp256k1

    check pool.get(pubInfo.peerId).isNone

  test "get filters for supported addresses (IPv4 with TCP or QUIC-v1)":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")
    let relayPeerId = PeerId.random().expect("could not generate relay peerId")
    let ipv6Addr =
      MultiAddress.init("/ip6/::1/tcp/4242").expect("could not create multiaddr")
    let udpAddr =
      MultiAddress.init("/ip4/127.0.0.1/udp/4242").expect("could not create multiaddr")
    let tcpAddr =
      MultiAddress.init("/ip4/127.0.0.1/tcp/4243").expect("could not create multiaddr")
    let quicAddr = MultiAddress.init("/ip4/127.0.0.1/udp/4244/quic-v1").expect(
        "could not create multiaddr"
      )
    # Circuit-relay addresses
    let tcpCircuitAddr = MultiAddress.init(
      "/ip4/127.0.0.1/tcp/4245/p2p/" & $relayPeerId & "/p2p-circuit"
    ).expect("could not create multiaddr")
    let quicCircuitAddr = MultiAddress.init(
      "/ip4/127.0.0.1/udp/4246/quic-v1/p2p/" & $relayPeerId & "/p2p-circuit"
    ).expect("could not create multiaddr")
    let ipv6CircuitAddr = MultiAddress.init(
      "/ip6/::1/tcp/4247/p2p/" & $relayPeerId & "/p2p-circuit"
    ).expect("could not create multiaddr")

    peerStore[MixPubKeyBook][pubInfo.peerId] = pubInfo.mixPubKey
    peerStore[KeyBook][pubInfo.peerId] =
      PublicKey(scheme: Secp256k1, skkey: pubInfo.libp2pPubKey)

    # Only IPv6 - should return none
    peerStore[AddressBook][pubInfo.peerId] = @[ipv6Addr]
    check pool.get(pubInfo.peerId).isNone

    # Only UDP (without QUIC-v1) - should return none
    peerStore[AddressBook][pubInfo.peerId] = @[udpAddr]
    check pool.get(pubInfo.peerId).isNone

    # IPv6 and UDP first, then TCP - should return TCP
    peerStore[AddressBook][pubInfo.peerId] = @[ipv6Addr, udpAddr, tcpAddr]
    check pool.get(pubInfo.peerId).get().multiAddr == tcpAddr

    # UDP first, then QUIC-v1 - should return QUIC-v1
    peerStore[AddressBook][pubInfo.peerId] = @[udpAddr, quicAddr]
    check pool.get(pubInfo.peerId).get().multiAddr == quicAddr

    # TCP and QUIC-v1 both available - should return first match (TCP)
    peerStore[AddressBook][pubInfo.peerId] = @[tcpAddr, quicAddr]
    check pool.get(pubInfo.peerId).get().multiAddr == tcpAddr

    # TCP circuit-relay - should be supported
    peerStore[AddressBook][pubInfo.peerId] = @[tcpCircuitAddr]
    check pool.get(pubInfo.peerId).get().multiAddr == tcpCircuitAddr

    # QUIC-v1 circuit-relay - should be supported
    peerStore[AddressBook][pubInfo.peerId] = @[quicCircuitAddr]
    check pool.get(pubInfo.peerId).get().multiAddr == quicCircuitAddr

    # IPv6 circuit-relay - should return none (unsupported transport)
    peerStore[AddressBook][pubInfo.peerId] = @[ipv6CircuitAddr]
    check pool.get(pubInfo.peerId).isNone

    # Mixed: unsupported circuit-relay first, then supported - should return supported
    peerStore[AddressBook][pubInfo.peerId] = @[ipv6CircuitAddr, tcpCircuitAddr]
    check pool.get(pubInfo.peerId).get().multiAddr == tcpCircuitAddr

  test "peerIds returns all peer IDs":
    for i in 0 ..< mixNodes.len:
      let pubInfo = mixNodes.getMixPubInfoByIndex(i).expect("could not get pub info")
      pool.add(pubInfo)

    let peerIds = pool.peerIds()

    check peerIds.len == mixNodes.len

    for i in 0 ..< mixNodes.len:
      let pubInfo = mixNodes.getMixPubInfoByIndex(i).expect("could not get pub info")
      check pubInfo.peerId in peerIds

  test "len returns correct count":
    check pool.len == 0

    for i in 0 ..< 3:
      let pubInfo = mixNodes.getMixPubInfoByIndex(i).expect("could not get pub info")
      pool.add(pubInfo)
      check pool.len == i + 1

  test "get prefers LastSeenOutboundBook over AddressBook":
    let pubInfo = mixNodes.getMixPubInfoByIndex(0).expect("could not get pub info")
    let addressBookAddr = MultiAddress.init("/ip4/192.168.1.1/tcp/4242").expect(
        "could not create multiaddr"
      )
    let lastSeenAddr =
      MultiAddress.init("/ip4/10.0.0.1/tcp/4243").expect("could not create multiaddr")
    let lastSeenIpv6Addr =
      MultiAddress.init("/ip6/::1/tcp/4244").expect("could not create multiaddr")

    peerStore[MixPubKeyBook][pubInfo.peerId] = pubInfo.mixPubKey
    peerStore[KeyBook][pubInfo.peerId] =
      PublicKey(scheme: Secp256k1, skkey: pubInfo.libp2pPubKey)
    peerStore[AddressBook][pubInfo.peerId] = @[addressBookAddr]

    # When LastSeenOutboundBook has a supported address, prefer it
    peerStore[LastSeenOutboundBook][pubInfo.peerId] = Opt.some(lastSeenAddr)
    check pool.get(pubInfo.peerId).get().multiAddr == lastSeenAddr

    # When LastSeenOutboundBook has unsupported address (IPv6), fall back to AddressBook
    peerStore[LastSeenOutboundBook][pubInfo.peerId] = Opt.some(lastSeenIpv6Addr)
    check pool.get(pubInfo.peerId).get().multiAddr == addressBookAddr

    # When LastSeenOutboundBook is empty, fall back to AddressBook
    peerStore[LastSeenOutboundBook][pubInfo.peerId] = Opt.none(MultiAddress)
    check pool.get(pubInfo.peerId).get().multiAddr == addressBookAddr

  test "multiple operations sequence":
    # Add 3 nodes
    for i in 0 ..< 3:
      let pubInfo = mixNodes.getMixPubInfoByIndex(i).expect("could not get pub info")
      pool.add(pubInfo)

    check pool.len == 3

    # Remove middle node
    let middlePubInfo =
      mixNodes.getMixPubInfoByIndex(1).expect("could not get pub info")
    discard pool.remove(middlePubInfo.peerId)

    check:
      pool.len == 2
      pool.get(middlePubInfo.peerId).isNone

    # Add two more nodes
    for i in 3 ..< 5:
      let pubInfo = mixNodes.getMixPubInfoByIndex(i).expect("could not get pub info")
      pool.add(pubInfo)

    check pool.len == 4
